#!/usr/bin/env perl 
#===============================================================================
#
#         FILE: NumbersDB.pm
#
#  DESCRIPTION: Data Access Layer between DB and program
#
#      OPTIONS: ---
# REQUIREMENTS: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Timothy Moll
# ORGANIZATION: 
#      VERSION: 0.2
#      CREATED: 23/12/14 11:19:12
#     REVISION: ---
#===============================================================================

package ExpensesDB;
use Moose;
extends 'DAL';

use constant RAW_TABLE=>'RawData';
use constant EXPENSES_TABLE=>'Expenses';
use constant CLASSIFIED_DATA_TABLE=>'Classifications';
use constant CLASSIFICATION_DEFINITION_TABLE=>'ClassificationDef';
use constant ACCOUNT_DEFINITION_TABLE=>'AccountDef';
use constant LOADER_DEFINITION_TABLE=>'LoaderDef';
use constant PROCESSOR_DEFINITION_TABLE=>'ProcessorDef';
use constant ACCOUNT_LOADERS_TABLE=>'AccountLoaders';
use constant EXPENSE_RAW_MAPPING_TABLE => 'ExpenseRawMapping';

use strict;
use warnings;
use utf8;

use DBI;
use DataTypes::Expense;
use Time::Piece;

sub addRawExpense
{
	my ($self, $rawLine, $account) = @_;
	my $dbh = $self->_openDB();
	$dbh->{HandleError} = \&_handleRawError;

	my $insertString = 'insert into ' . RAW_TABLE . '(rawStr, importDate, aid) values (?, ?, ?)';
	my $sth = $dbh->prepare($insertString);
	my @bindValues;
	$bindValues[0] = $rawLine;
	$bindValues[1] = gmtime();
	$bindValues[2] = $account;
	$sth->execute(@bindValues);

	$dbh->disconnect();
}

sub _handleRawError
{
	my $error = shift;
	unless ($error =~ m/UNIQUE constraint failed: RawData.rawStr/)
	{
		print 'Error performing raw insert: ',$error,"\n";
	}
	return 1;
}

sub getUnclassifiedLines
{
	my ($self, $rawLine, $account) = @_; 
	my $dbh = $self->_openDB();

# TODO: this what if there is no matching account?
	my $selectString = 'select processor,rawstr,rid,rawdata.aid,ccy  from rawdata,accountdef,processordef where rid not in (select distinct rid from expenserawmapping) and rawdata.aid = accountdef.aid and accountdef.pid=processordef.pid';

	my $sth = $dbh->prepare($selectString);
	$sth->execute();

	my @returnArray;
	while (my @row = $sth->fetchrow_array())
	{
		push (@returnArray, \@row);
	}

	$sth->finish();
	$dbh->disconnect();

	return \@returnArray;
}

sub getCurrentClassifications
{
	my ($self) = @_;
	my %classifications;
	my $dbh = $self->_openDB();

	my $sth = $dbh->prepare('select cid,name from ClassificationDef');
	$sth->execute();


	while (my $row = $sth->fetchrow_arrayref)
	{
		$classifications{$$row[0]} = $$row[1];
	}

	$sth->finish();

	return \%classifications;
}

sub saveExpense
{
# just dealing with new expenses so far...
	my ($self, $expense) = @_;

	my $dbh = $self->_openDB();

	my $insertString='insert into '.EXPENSES_TABLE.' (aid, description, amount, ccy, amountFX, ccyFX, fxRate, commission, date) values (?, ?, ?, ?, ?, ?, ?, ?, ?)';
	my $sth = $dbh->prepare($insertString);
	$sth->execute($self->_makeTextQuery($expense->getAccountID()),
			$self->_makeTextQuery($expense->getExpenseDescription()),
			$expense->getExpenseAmount(),
			$expense->getCCY(),
			$expense->getFXAmount(),
			$expense->getFXCCY(),
			$expense->getFXRate(),
			$expense->getCommission(),
			$expense->getExpenseDate());
	$sth->finish();

# TODO: make this a bit safer
	$sth=$dbh->prepare('select max(eid) from expenses');
	$sth->execute();
	$expense->setExpenseID($sth->fetchrow_arrayref()->[0]);
	$sth->finish();

	foreach (@{$expense->getRawIDs()})
	{
		my $insertString='insert into '. EXPENSE_RAW_MAPPING_TABLE .' (eid, rid) values (?, ?)';
		$sth=$dbh->prepare($insertString);
		$sth->execute($expense->getExpenseID(), $self->_makeTextQuery($_));
		$sth->finish();
	}

	my $insertString2='insert into '.CLASSIFIED_DATA_TABLE.' (eid, cid, confirmed) values (?, ?, 0)';
	$sth = $dbh->prepare($insertString2);
	$sth->execute($self->_makeTextQuery($expense->getExpenseID()), $self->_makeTextQuery($expense->getExpenseClassification()));
	$sth->finish();

	$dbh->disconnect();
}

sub mergeExpenses
{
	my ($self, $primaryExpense, $secondaryExpense) = @_;
	my $dbh = $self->_openDB();
	$dbh->{AutoCommit} = 0;

	eval
	{
		my $sth=$dbh->prepare('select rid from expenserawmapping where eid = ?');
		$sth->execute($secondaryExpense);
		foreach my $row ( $sth->fetchrow_arrayref())
		{
			my $sth2 = $dbh->prepare('insert into expenserawmapping (eid, rid) values(?,?)');
			$sth2->execute($primaryExpense, $row->[0]);
		}
		$sth = $dbh->prepare('delete from expenses where eid = ?');
		$sth->execute($secondaryExpense);
		$sth = $dbh->prepare('delete from expenserawmapping where eid = ?');
		$sth->execute($secondaryExpense);
		$sth = $dbh->prepare('delete from classifications where eid = ?');
		$sth->execute($secondaryExpense);

		$dbh->commit();

	};

    if($@)
	{
		warn "Error inserting the link and tag: $@\n";
		$dbh->rollback();
	}

}

sub confirmClassification
{
	my ($self, $expenseID) = @_;
	my $dbh = $self->_openDB();
	my $sth = $dbh->prepare('update classifications set confirmed = 1 where eid = ?');
	$sth->execute($expenseID);
	$sth->finish();
}

# Removes existing classifications so can be used also to update an existing one
sub saveClassification
{
	my ($self, $expenseID, $classificationID, $confirmed) = @_;
	my $dbh = $self->_openDB();
	$dbh->{AutoCommit} = 0;

	eval
	{
		my $sth = $dbh->prepare('delete from classifications where eid = ?');
		$sth->execute($expenseID);
		$sth->finish();
		$sth = $dbh->prepare('insert into classifications (eid, cid, confirmed) values (?, ?, ?)');
		$sth->execute($expenseID, $classificationID, $confirmed);
		$sth->finish();
		$dbh->commit();
		$dbh->disconnect();
	};
    
	if($@)
	{
		warn "Error saving classification $classificationID for expense $expenseID\n";
		$dbh->rollback();
	}
}

sub saveAmount
{
	my ($self, $expenseID, $amount) = @_;
	my $dbh = $self->_openDB();
	my $sth = $dbh->prepare('update expenses set amount = ?, modified = ? where eid = ?');
	$sth->execute($amount, $self->_getCurrentDateTime() ,$expenseID);
	$sth->finish();
	$dbh->disconnect();
}

sub getValidClassifications
{
	my ($self, $expense) = @_;
	my $dbh = $self->_openDB();
	my $sth = $dbh->prepare("select cid from classificationdef where date(validfrom) <= date(?) and (validto = '' or date(validto) >= date(?))");
    $sth->execute($expense->getExpenseDate(), $expense->getExpenseDate());

	my @results;
	while (my $row = $sth->fetchrow_arrayref) {push (@results, $$row[0])}
	$sth->finish();
	return \@results;
}

sub getClassificationStats
{
	my ($self, $expense) = @_;
	my $dbh = $self->_openDB();
	my $sth = $dbh->prepare("select cid, count (*) from expenses e, classifications c where date(e.date) > date( ?, 'start of month','-12 months') and e.eid = c.eid group by cid");
    $sth->execute($expense->getExpenseDate());

	my @results;
	while (my @row = $sth->fetchrow_array) {push (@results, \@row)}
	$sth->finish();
	return \@results;
}

sub getExactMatches
{
	my ($self, $expense) = @_;
	my $dbh = $self->_openDB();
	my $sth = $dbh->prepare('select cid, count (*) from expenses e, classifications c where e.description = ? and e.eid = c.eid group by cid');
    $sth->execute($expense->getExpenseDescription());

	my @results;
	while (my @row = $sth->fetchrow_array) {push (@results, \@row)}
	$sth->finish();
	return \@results;
}

sub getAccounts
{
	my ($self) = @_;
    my @accounts;
	my $dbh = $self->_openDB();

    my $sth = $dbh->prepare('select ldr.loader, a.name, a.aid, l.buildStr from accountdef a, accountloaders l, loaderdef ldr where a.aid = l.aid and a.lid = ldr.lid and l.enabled;');
    $sth->execute();

    while (my @row = $sth->fetchrow_array)
    {
        push (@accounts, \@row);
    }

    $sth->finish();
    
    return \@accounts;
}

1;
