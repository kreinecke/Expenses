package backend

import (
	"b2/errors"
	"b2/manager"
	"b2/webhandler"
	"database/sql"
	"encoding/json"
	"net/http"

	"github.com/mattn/go-sqlite3"
)

// Backend struct holds shared dependencies for the whole program and
// allows each component to communicate with others
type Backend struct {
	// Managed Components
	Accounts        manager.Manager
	Assets          manager.Manager
	Classifications manager.Manager
	Documents       manager.Manager
	Expenses        manager.Manager
	Mappings        manager.Manager
	Series          manager.Manager
	Splitwise       Splitwise

	DB *sql.DB

	// ReprocessDocument is a channel that when a uint64 id is written to it will request the document
	// component to reprocess that document
	ReprocessDocument chan uint64
	// ReprocessExpense is a channel that when a uint64 id is written to it will request the expense
	// component to reprocess that document
	ReprocessExpense chan uint64
	// ReloadDocumentMappings will reload the expense mappings for the document id provided
	ReloadDocumentMappings chan uint64
	// ReloadExpenseMappings will reload the document mappings for the expense id provided
	ReloadExpenseMappings chan uint64
	// ReloadAssetSeries will reload the series on an asset
	ReloadAssetSeries chan uint64
	// ReclassifyDocuments will reclassify all non-confirmed documents
	ReclassifyDocuments chan bool
	// Change is used by the change notifier to be alerted to when there are changes on the server
	Change       chan int
	DocsLocation string
}

// Splitwise holds the credentials for a splitwise user
type Splitwise struct {
	User        uint64
	BearerToken string
}

// Instance returns a pointer to a new fully instantiated backend instance
func Instance(dataSourceName string) *Backend {
	backend := new(Backend)
	err := backend.loadDB(dataSourceName)
	if err != nil {
		panic(err)
	}
	backend.ReprocessDocument = make(chan uint64, 100)
	backend.ReloadDocumentMappings = make(chan uint64, 100)
	backend.ReprocessExpense = make(chan uint64, 100)
	backend.ReloadExpenseMappings = make(chan uint64, 100)
	backend.ReclassifyDocuments = make(chan bool, 100)
	backend.Change = make(chan int, 100)
	backend.ReloadAssetSeries = make(chan uint64, 100)
	return backend
}

// Start invokes the processes to listen for changes and other events on the chans
// This should be called after all dependencies are configured for the backend
func (backend *Backend) Start() {
	go backend.listenReproDoc()
	go backend.listenDocMapping()
	go backend.listenReproExpense()
	go backend.listenExMapping()
	go backend.listenReclassDocs()
	go backend.reloadAssetMappings()
}

func (backend *Backend) reloadAssetMappings() {
	cpt := backend.Assets.Component()
	if _, ok := cpt.(component); !ok {
		panic("Incorrect backend setup")
	}
	for {
		id := <-backend.ReloadAssetSeries
		thing, err := backend.Assets.Get(id)
		if err != nil {
			errors.Print(errors.Wrap(err, "backend.reloadAssetMappings"))
		}
		cpt.(component).AfterLoad(thing)
	}
}

func (backend *Backend) listenExMapping() {
	cpt := backend.Expenses.Component()
	if _, ok := cpt.(component); !ok {
		panic("Incorrect backend setup")
	}
	for {
		id := <-backend.ReloadExpenseMappings
		thing, err := backend.Expenses.Get(id)
		if err != nil {
			errors.Print(errors.Wrap(err, "backend.listenExMapping"))
		}
		cpt.(component).AfterLoad(thing)
	}
}

func (backend *Backend) listenDocMapping() {
	cpt := backend.Documents.Component()
	if _, ok := cpt.(component); !ok {
		panic("Incorrect backend setup")
	}
	for {
		id := <-backend.ReloadDocumentMappings
		thing, err := backend.Documents.Get(id)
		if err != nil {
			errors.Print(errors.Wrap(err, "backend.listenDocMapping"))
		}
		cpt.(component).AfterLoad(thing)
	}
}

func (backend *Backend) listenReproExpense() {
	cpt := backend.Expenses.Component()
	if _, ok := cpt.(component); !ok {
		panic("Incorrect backend setup")
	}
	for {
		id := <-backend.ReprocessExpense
		cpt.(component).Process(id)
	}
}

func (backend *Backend) listenReproDoc() {
	cpt := backend.Documents.Component()
	if _, ok := cpt.(component); !ok {
		panic("Incorrect backend setup")
	}
	for {
		id := <-backend.ReprocessDocument
		cpt.(component).Process(id)
	}
}

func (backend *Backend) listenReclassDocs() {
	cpt := backend.Documents.Component()
	if _, ok := cpt.(docmgr); !ok {
		panic("Incorrect document backend setup")
	}
	for {
		_ = <-backend.ReclassifyDocuments
		cpt.(docmgr).ReclassifyAll()
	}
}

// Process is the http handler for requests that need a message to be sent on a chan
// to one of the components of the application
func (backend *Backend) Process(w http.ResponseWriter, req *http.Request) {
	switch req.Method {
	case "POST":
		type dataStruct struct {
			ID   uint64 `json:"id"`
			Type string `json:"type"`
		}
		decoder := json.NewDecoder(req.Body)
		decoder.DisallowUnknownFields()
		data := new(dataStruct)
		err := decoder.Decode(&data)
		if err != nil {
			webhandler.ReturnError(err, w)
			return
		}
		switch data.Type {
		case "document":
			backend.ReprocessDocument <- data.ID
		case "expense":
			backend.ReprocessExpense <- data.ID
		default:
			http.Error(w, http.StatusText(400), 400)
		}
	case "OPTIONS":
		w.Header().Set("Access-Control-Allow-Methods", "OPTIONS, POST")
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Headers", "content-type")
	default:
		http.Error(w, http.StatusText(405), 405)
	}
}

func (backend *Backend) loadDB(dataSourceName string) error {
	sqlite3conn := []*sqlite3.SQLiteConn{}
	sql.Register("expenses_db",
		&sqlite3.SQLiteDriver{
			ConnectHook: func(conn *sqlite3.SQLiteConn) error {
				sqlite3conn = append(sqlite3conn, conn)
				conn.RegisterUpdateHook(func(op int, db string, table string, rowid int64) {
					switch op {
					case sqlite3.SQLITE_INSERT:
						//	fmt.Println("Notified of insert on db", db, "table", table, "rowid", rowid)
					}
				})
				return nil
			},
		})
	db, err := sql.Open("expenses_db", dataSourceName)
	if err != nil {
		return errors.Wrap(err, "backend.loadDB")
	}
	if err = db.Ping(); err != nil {
		return errors.Wrap(err, "backend.loadDB")
	}
	backend.DB = db
	return nil
}
