package documents

import (
	"b2/errors"
	"database/sql"
)

func cleanDate(date string) string {
	// todo improve date handling
	if date == "" {
		return date
	}
	return date[0:10]
}

func findDocuments(query *Query, db *sql.DB) ([]uint64, error) {
	dbQuery := `
		select
			distinct(d.did)
		from 
			documents d
		left join
			DocumentExpenseMapping dem on d.did = dem.did
		where
			not d.deleted`
	if query.Starred == true {
		dbQuery += ` and d.Starred`
	} else {
		dbQuery += ` and not d.Starred`
	}

	if query.Archived == true {
		dbQuery += ` and d.archived`
	} else {
		dbQuery += ` and not d.archived`
	}

	if query.Unmatched == true {
		dbQuery += ` and 
				(not dem.confirmed 
				or dem.confirmed is null)`
	}
	dbQuery += ` order by d.did desc`
	rows, err := db.Query(dbQuery)
	defer rows.Close()
	if err != nil {
		return nil, errors.Wrap(err, "documents.findDocuments")
	}
	var dids []uint64
	for rows.Next() {
		var did uint64
		err = rows.Scan(&did)
		if err != nil {
			return nil, errors.Wrap(err, "documents.findDocuments")
		}
		dids = append(dids, did)
	}
	return dids, errors.Wrap(err, "documents.findDocuments")
}

func loadDocument(did uint64, db *sql.DB) (*Document, error) {
	rows, err := db.Query(`
        select
            d.date,
            d.filename,
            d.text,
            d.deleted,
			d.filesize,
			d.starred,
			d.archived
        from
            documents d
        where
            d.did = $1`,
		did)
	defer rows.Close()
	if err != nil {
		return nil, errors.Wrap(err, "documents.loadDocument")
	}
	document := new(Document)
	if rows.Next() {
		err = rows.Scan(&document.Date,
			&document.Filename,
			&document.Text,
			&document.Deleted,
			&document.Filesize,
			&document.Starred,
			&document.Archived)
		document.ID = did
	} else {
		return nil, errors.New("Document not found", errors.ThingNotFound, "documents.loadDocument", true)
	}
	if err != nil {
		return nil, errors.Wrap(err, "documents.loadDocument")
	}
	return document, nil
}

func createDocument(d *Document, db *sql.DB) error {
	err := d.Check()
	if err != nil {
		return errors.Wrap(err, "documents.createDocument")
	}
	d.Lock()
	defer d.Unlock()
	rows, err := db.Query(`
		select
			did
		from
			documents
		where
			filename = $1
			and filesize = $2`,
		d.Filename, d.Filesize)
	defer rows.Close()
	if err != nil {
		return errors.Wrap(err, "documents.createDocument")
	}
	if rows.Next() {
		return errors.New("existing document, not saving", nil, "documents.createDocument", true)
	}
	res, err := db.Exec(`
		insert into
			documents (
				filename,
				date,
				text,
				filesize,
				deleted,
				starred,
				archived
				)
			values ($1, $2, $3, $4, $5, $6, $7)`,
		d.Filename,
		d.Date,
		d.Text,
		d.Filesize,
		d.Deleted,
		d.Starred,
		d.Archived)
	if err != nil {
		return errors.Wrap(err, "documents.createDocument")
	}
	did, err := res.LastInsertId()
	if err == nil && did > 0 {
		d.ID = uint64(did)
	} else if did == 0 {
		return errors.New("Error saving new document", errors.InternalError, "documents.createDocument", true)
	}
	return errors.Wrap(err, "documents.createDocument")
}

func updateDocument(d *Document, db *sql.DB) error {
	d.RLock()
	defer d.RUnlock()
	_, err := db.Exec(`
		update
			documents
		set
			filename = $1,
			date = $2,
			text = $3,
			filesize = $4,
			deleted = $5,
			starred = $6,
			archived = $7
		where
			did = $8`,
		d.Filename,
		d.Date,
		d.Text,
		d.Filesize,
		d.Deleted,
		d.Starred,
		d.Archived,
		d.ID)
	return errors.Wrap(err, "documents.updateDocument")
}

func deleteDocument(d *Document, db *sql.DB) error {
	// Assuming we're getting a locked document
	_, err := db.Exec(`delete from documents where did = $1`, d.ID)
	return errors.Wrap(err, "documents.deleteDocument")
}

func reclassifyableDocs(db *sql.DB) ([]uint64, error) {
	dbQuery := `
		select
			distinct(d.did)
		from 
			documents d
		left join
			DocumentExpenseMapping dem on d.did = dem.did
		where
			not d.deleted
			and not d.starred
			and not d.archived
			and
				(not dem.confirmed 
				or dem.confirmed is null)`
	rows, err := db.Query(dbQuery)
	defer rows.Close()
	if err != nil {
		return nil, errors.Wrap(err, "documents.reclassifyableDocs")
	}
	var dids []uint64
	for rows.Next() {
		var did uint64
		err = rows.Scan(&did)
		if err != nil {
			return nil, errors.Wrap(err, "documents.reclassifyableDocs")
		}
		dids = append(dids, did)
	}
	return dids, errors.Wrap(err, "documents.reclassifyableDocs")
}
