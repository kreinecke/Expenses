#!/usr/bin/perl

package Loader_Aqua;
use Moose;
extends 'Loader';

use strict;
use warnings;

use WWW::Mechanize;
use HTTP::Cookies;

use DataTypes::GenericRawLine;

use Switch;

has 'input_data' => ( is => 'rw', isa => 'ArrayRef', writer=>'set_input_data', reader=>'get_input_data', default=> sub { my @empty; return \@empty});
has 'USER_NAME' => ( is => 'rw', isa=>'Str', writer=>'setUserName');
has 'SURNAME' => ( is => 'rw', isa=>'Str', writer=>'setSurname' );
has 'SECRET_WORD' => ( is => 'rw', isa=>'Str', writer=>'setSecretWord' );
has 'SECRET_NUMBERS' => ( is => 'rw', isa=>'Str', writer=>'setSecretNo' );
has 'cutoff_date' => (is => 'rw', isa=>'Str', writer=>'setCutoffDate', reader=>'getCutoffDate');
has 'process_statement' => (is => 'rw', isa=>'Bool', writer=>'setProcessStatement', reader=>'getProcessStatement');

use constant DATE_INDEX => 0;
use constant DESCRIPTION_INDEX => 2;
use constant AMOUNT_INDEX => 3;
use constant CREDIT_DEBIT_INDEX => 4;

# build string formats:
# file; filename
# notfile; username; surname; secretword; secretnumber; processStatement; (cutoff date)
sub BUILD
{
	my ($self) = @_;
	my @buildParts = split (';' ,$self->build_string);
	# if it is a file
	if ($buildParts[0])
	{
		$self->setFileName($buildParts[1]);
	}
	else
	{

		$self->setUserName($buildParts[1]);
		$self->setSurname($buildParts[2]);
		$self->setSecretWord($buildParts[3]);
		$self->setSecretNo($buildParts[4]);
		$self->setProcessStatement($buildParts[5]);
		$self->setCutoffDate($buildParts[6]) if defined ($buildParts[6]);
	}
}

# Use the line when contstructing the record
sub _useInputLineInternal
{
    my ($self, $line) = @_;
    return 1 if ($_ =~ m/abbr/);
    return 0;
}

sub _getDate
{
    my ($self, $dateString) = @_; 
	if ($dateString =~ m/([0-9]{2})\/([0-9]{2})\/([0-9]{4})/)
	{
		return "$3-$2-$1";
	}
	elsif ($dateString =~ m/([0-9]{2}) ([A-Za-z]{3}) ([0-9]{2})/)
	{
		my $day = $1;
		my $year = $3;
		my $month;
		switch($2)
		{   
			case 'Jan' { $month = '01'; }
			case 'Feb' { $month = '02'; }
		    case 'Mar' { $month = '03'; }
		    case 'Apr' { $month = '04'; }
		    case 'May' { $month = '05'; }
		    case 'Jun' { $month = '06'; }
		    case 'Jul' { $month = '07'; }
		    case 'Aug' { $month = '08'; }
		    case 'Sep' { $month = '09'; }
		    case 'Oct' { $month = '10'; }
		    case 'Nov' { $month = '11'; }
		    case 'Dec' { $month = '12'; }
		}   
		return "20$year-$month-$day";
	}
}

sub _cleanAmount
{
	my ($self, $amount) = @_;
	$amount =~ m/([0-9,.]+)/;
	return $1;
}

sub _afterCutoffDate
{
	my ($self, $line)  = @_;
	return 1 unless (defined $self->getCutoffDate());
	$self->getCutoffDate() =~ m/([0-9]{4})-([0-9]{2})-([0-9]{2})/;
	my $year = $1;
	my $month = $2;
	my $day = $3;
	$line->getTransactionDate() =~ m/([0-9]{4})-([0-9]{2})-([0-9]{2})/;
	return 1 if ($1 > $year);
	return 1 if ($1 >= $year and $2 > $month);
	return 1 if ($1 >= $year and $2 >= $month and $3 > $day);
	return 0;
}

sub _processInputLine
{
    my ($self, $line ) = @_;

	my $processedLine = GenericRawLine->new();
	#<td>03 Jan 15</td><td>05 Jan 15</td><td>Expense  Description</td><td class="right">£99.00 <abbr title="debit">DR</abbr></td>
	if ($line =~ m/<td>([^<]*)<\/td><td>([^<]*)<\/td><td>([^<]*)<\/td><td class="right">([^<]*)<abbr title="[a-z]*">([^<]*)<\/abbr><\/td>/)
	{
		$processedLine->setTransactionDate($self->_getDate($1));
		$processedLine->setProcessedDate($self->_getDate($2));
		$processedLine->setDescription($3);
		$processedLine->setAmount($self->_cleanAmount($4));
		$processedLine->setDebitCredit($5);
	}
	#<td class="ten">01/11/2014</td><td class="thirtytwo">PAYMENT RECEIVED - THANK YOU</td><td class="right">£50.00   <abbr title="credit">CR</abbr> </td>
	#<td class="ten">25/11/2014</td><td class="thirtytwo">Expense Description</td><td class="right">£99.00  <abbr title="debit">DR</abbr> </td>
	elsif ($line =~ m/<td class="ten">([^<]*)<\/td><td class="thirtytwo">([^<]*)<\/td><td class="right">([^<]*)<abbr title="[a-z]*">([^<]*)<\/abbr> <\/td>/)
	{
		$processedLine->setTransactionDate($self->_getDate($1));
		$processedLine->setDescription($2);
		$processedLine->setAmount($self->_cleanAmount($3));
		$processedLine->setDebitCredit($4);
	}

	return unless ($self->_afterCutoffDate($processedLine));

	my $previousLine = $self->get_input_data()->[-1];
	$previousLine = GenericRawLine->new() unless (defined $previousLine);

	if ($processedLine->getAmount =~ m/^0?\.00$/
		and $processedLine->getDebitCredit() eq $previousLine->getDebitCredit()
		and $processedLine->getTransactionDate() eq $previousLine->getTransactionDate()
		and $processedLine->getDescription() =~ m/([0-9,.]*) *([A-Z]{3})/)
	{
		$previousLine->setFXAmount($1);
		$previousLine->setFXCCY($2);
		return;
	}

	return $processedLine;

}

sub _setOutputData
{
    my ($self, $lines) = @_;
    my $output = $self->get_input_data();
    foreach (@$lines)
    {
        next unless ($self->_useInputLineInternal($_));
		my $nextLine = $self->_processInputLine($_);
        push( @$output, $nextLine ) if ($nextLine);
    }
}

sub _returnStrings
{
	my ($self) = @_;
	my $input_data = $self->get_input_data();
	my @returnStrs;
	foreach (@$input_data)
	{
		push (@returnStrs, $_->toString());
	}
	return \@returnStrs;
}

###############################################################################
## All functions below for navigation of website ##############################
###############################################################################

sub _pullOnlineData
{
	my $self = shift;
	my @result;
	my $agent = WWW::Mechanize->new( cookie_jar => {} );
	$agent->get('https://service.aquacard.co.uk/aqua/web_channel/cards/security/logon/logon.aspx');
	$agent->form_id('mainform');
	$agent->set_fields('datasource_3a4651d1-b379-4f77-a6b1-5a1a4855a9fd' => $self->USER_NAME);
	$agent->set_fields('datasource_2e7ba395-e972-4a25-8d19-9364a6f06132' => $self->SURNAME);
	$agent->set_fields( '__EVENTTARGET' =>'Target_5d196b33-e30f-442f-a074-1fe97c747474' );
	$agent->set_fields( '__EVENTARGUMENT' =>'Target_5d196b33-e30f-442f-a074-1fe97c747474' );
	$agent->submit();

	$agent->form_id('mainform');
	$agent->set_fields('datasource_20056b2c-9455-4e42-aeba-9351afe0dbe1' => $self->SECRET_WORD );

	my $secretNumbers = $self->_getPasscodes($agent);
	$agent->set_fields('selectedvalue_dc28fef3-036f-4e48-98a0-586c9a4fbb3c' => $$secretNumbers[0]);
	$agent->set_fields('selectedvalue_f758fdb6-4b2c-4272-b785-cb3989b67901' => $$secretNumbers[1]);
	$agent->set_fields( '__EVENTTARGET' =>'Target_53ab78d3-78ed-46f1-a777-1fd7957e1165' );
	$agent->set_fields( '__EVENTARGUMENT' =>'Target_53ab78d3-78ed-46f1-a777-1fd7957e1165' );
	$agent->submit();

	my $pageNumber = 0;
	$pageNumber = -2 if ($self->_getPageNumber($agent) == -1);

	while ($self->_getPageNumber($agent) > $pageNumber)
	{
		my @lines = split ("\n",$agent->content());
		$self->_setOutputData(\@lines);
		$pageNumber = $self->_getPageNumber($agent);
		$agent->click_button( name => $self->_getNextPageLinkName($agent) ) unless ($pageNumber == -1 or ! defined $self->_getNextPageLinkName($agent));
	}

	$self->_doPostback($agent, 'View statements');

	if ($self->getProcessStatement())
	{
		for (my $i=0; $i < 5; $i++)
		{
			$agent->post('https://service.aquacard.co.uk/aqua/web_channel/cards/servicing/youraccount/statement.aspx',
				[	'__EVENTTARGET' => '',
					'__EVENTARGUMENT' => '',
					'__VIEWSTATE' => '',
					'Target_f62e6d84-ef4f-4981-9b63-2c14b74ea065' => $self->_getViewState($agent),
					'fixle' => '',
					'selectedvalue_cfb4c82a-5338-4170-bafd-55c914904bcc' => $i,
				]);

			$self->_doPostback($agent, 'Transactions');
			$pageNumber = 0;
			$pageNumber = -2 if ($self->_getPageNumber($agent) == -1);

			while ($self->_getPageNumber($agent) > $pageNumber)
			{
				my @lines = split ("\n",$agent->content());
				$self->_setOutputData(\@lines);
				if ($self->_getPageNumber($agent) > $pageNumber)
				{
					$pageNumber = $self->_getPageNumber($agent);
					$agent->click_button( name => $self->_getNextPageLinkName($agent) ) if (defined $self->_getNextPageLinkName($agent));
				}
			}
			$agent->get('/sitecore/content/Aqua/Web_Channel/Cards/Servicing/YourAccount/Statement.aspx');
		}
	}

	return $self->_returnStrings();

}


sub _getViewState
{
	my ($self, $agent) = @_;
	#<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="/wEPDwUKLTU4NTgxOTI5OA9kFgRmD2QWAmYPFgIeBGhyZWYFKS9+L21lZGlhL0FxdWEvZ3JhcGhpY3MvaWNvbnMvZmF2aWNvbi5hc2h4ZAIBEBYCHgpvbmtleXByZXNzBTZqYXZhc2NyaXB0OnJldHVybiBXZWJGb3JtX0ZpcmVEZWZhdWx0QnV0dG9uKGV2ZW50LCAnJylkFgICAw8WBB4Dc3JjBTQvfi9tZWRpYS9BcXVhL2dyYXBoaWNzL2xvZ29zL0dlbmVyaWNQcmludEhlYWRlci5hc2h4HgNhbHRkZGQ=" />
	my $content = $agent->content;
	$content =~ m/<input type="hidden" name="__VIEWSTATE" id="__VIEWSTATE" value="([^"]*)"/;
	return $1;
}

sub _generateSecretNumbers
{
    my $self = shift;
# start with 0 so we can use 1 for 1 array referencing
# i.e. first number (we care about) is in array posn 1
    my @numbers = (0);
    push (@numbers, split('', $self->SECRET_NUMBERS));
    return \@numbers;
}

sub _getPasscodes
{
    my ($self, $agent) = @_;
    my @returnCodes;
    my $values = $self->_generateSecretNumbers();
    $agent->content() =~ m/([0-9]).. number of your Passcode.*([0-9]).. number of your Passcode/s;
    $returnCodes[0] = $$values[$1];
    $returnCodes[1] = $$values[$2];
    return \@returnCodes;
}

sub _doPostback
{
    my ($self, $agent, $searchString) = @_;
    $agent->content() =~ m/(doPostBack.*$searchString)/;
    my $string = $1;
    $string =~ m/^doPostBack\('([^']*)','([^']*)'\)/;
    $agent->form_id('mainform');
    $agent->set_fields('__EVENTTARGET' => "$1");
    $agent->set_fields('__EVENTARGUMENT' => "$2");
    $agent->submit();
}

sub _getPageNumber
{
    my ($self, $agent) = @_;
    $agent->content() =~ m/rgCurrentPage[^<]*<span>([^<]*)<\/span>/;
	my $pageNumber = $1;
	$pageNumber = -1 if (! defined $pageNumber or $pageNumber eq '');
    return $pageNumber;
}

sub _getNextPageLinkName
{
    my ($self, $agent) = @_;
    $agent->content() =~ m/<input type="submit" name="([^"]*)" value=" " title="Next Page" class="rgPageNext" \/>/;
    return $1;
}


1;
