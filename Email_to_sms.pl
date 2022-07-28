#!/usr/bin/perl
use strict;
use warnings;
use cPanelUserConfig;

use JSON;
use utf8;

use Email::Send::Sendmail;
use Log::Log4perl;
use Log::Dispatch::FileRotate;

while (my $body = <STDIN>) {
    my $data = parse($body);
    if (keys %$data == 3) {
           $msg = build_msg($data);
            # eval {send email } 
            #log 
    }
    #add to logger 
    # encode_json ({body => $body , res => $data});
}

sub parse {
    my $body = shift || undef;

    return {} unless (define $body);
    my $res;
    if($body =~ /Patient:(.*)Date of/gi) {
        $res->{firstname} = initialNameCleanup($1);
    }
    if($body =~ /Name:(.*)Attributed/gi) {
        $res->{lastname} = initialNameCleanup($1);
    }
    if($body =~ /Facility:(.*)/) {
        $res->{facility} = $1;
    }
    if($body =~ /\w+@[a-zA-Z_]+?\.[a-zA-Z]{2,3}/) {
        $res->{from_email} = $&;
    }
    my @reporcess = clean($res);
    if (scalar @missing > 0) {
        foreach my $field (@missing) {
            if(lc($field) eq 'firstname' || lc($field) eq 'lastname') {
                if($body =~ /Beneficiary, (.*), is being/) {
                    ($res->{firstname},$res->{lastname})  = ParseLnSFnMiNs($1);
                }
            }
            if(lc($field) eq 'facility') {
                if($body =~ /Emergency Department (ED) at (.*). See/) {
                    $res->{facility} = $1;
                }
            }
        }
    }

    return $res;
}

sub clean {
    my $res = shift;
    my @missing;
    foreach(qw/fistname lastname facility from_email/) {
        trim($res->{$_});
        if(!$res->{$_} || $res->{$_} eq '' || ! defined $res->{$_}) {
            delete $res>{$_};
            push (@missing,$_);
        }
    }

    return (@missing);
}



sub initialNameCleanup {
	my $name = shift;
	$name =~ s/\"/ /g;	#remove double quotes from name, this usually present at the start and end of the value
	$name =~ s/\([^\(\)]*\)|\[[^\[\]]*\]|\{[^\{\}]*\}/ /g;	#remove any thing between () [] {}
	$name =~ s/[\(\{\[\*].*$/ /g;		#remove any thing that follows (,{,[,*
	return $name;
}

sub ParseLnSFnMiNs {
    my $name = shift ;
    initialNameCleanup($name);
    my ($lname,$fname,$minitial,$namesuffix);

    my $count =0;
    trim($name);
    ##only single name
    if($name !~ / /ig ) {
      if($name =~ /\w+/ig){
            return ($name,'','','');
      }
    }
      if($name =~ /(,|LLC)/ig) {
    if($name =~ /\w+/ig){
        return ($name,'','','');
      }
    }
    if ($name =~ /\s{3,}/) {
        ($lname, $fname, $minitial, $namesuffix) = split '   ', $name;
    } else {
        $name =  ($name);
        $name =~ s/[^A-Z\_\-\']/ /ig;
        $name = trim ($name);
        # remove any name suffix from the name
        if ($name =~ /^(.*\s)?(JR|SR|III|II|IV)(\s.*)?$/i) {
            $name = $1 .' '. $3;
            $namesuffix = $2;
        }
        # rule : FN MI LN eg: (B JENKINS) J (MIDDLE) or (WILLIAM) J (DULKA)
        if ($name =~ /^(.{1,})\s+([A-Z])\s+(.{2,})$/i) {
            $fname = $1;
            $minitial = $2;
            $lname = $3;
        }
        # rule : FN LN eg: RICHARD MAYER
        elsif ($name =~ /^([A-Z\-\']+)\s+([A-Z\-\']+)$/i) {
            $fname = $1;
            $lname = $2;
            $minitial = '';
        } else {
            #remove the middle initial if there is no more clue, MI at first or middle or last
            if ($name =~ /^(.*)\b([A-Z])\b(.*)$/i && length($name) > 1) {
                $name = $1.' '.$3;
                $minitial = $2;
            }
            $name = trim($name);
            #handle JO ANN Last name
            if ($name =~ /^([A-Z]{2}\s\S+)\s(.+)$/i) {
                $fname = $1;
                $lname = $2;
            }
            #only option left is first word - first name others - last name
            elsif ($name =~ /^(\S+)\s+(\S+.*)$/i) {
                $fname = $1;
                $lname = $2;
            }
            else {
                $fname = $name;
            }
        }
    }

    return ($fname,$lname,$minitial,$namesuffix);
}

sub trim {
    my $s = shift;
    $s =~ s/^\s+|\s+$//g;
    return $s;
}

sub build_msg {
    my $data = shift;
    return <<MSG;
Your patient $data->{firstname} $data->{lastname} is currently being seen at $data->{facility}
MSG
}

sub logger {
    # my $self = shift;
    # Log::Log4perl::init($self->{_conf}->{db_logger});
    # return Log::Log4perl->get_logger($self->{_conf}->{db_logger_name});
}


sub get_mapper {
    my $db = connect_db();

}


sub connect_db {
    my $dsn      = $c->{database_dsn} || 'DBI:mysql:email';
    my $username = $c->{database_user};
    my $password = $c->{database_pw} ;
    my %attr     = (
        PrintError           => 0,    # turn off error reporting via warn()
        RaiseError           => 1,    # turn on error reporting via die()
        AutoCommit           => 1,
        mysql_auto_reconnect => 1,
    );
    return DBI->connect($dsn, $username, $password, \%attr) || die "Unable to connect to DB $@";
}

=pod
log4perl.category.dashboardlog          = ALL, Logfile
log4perl.appender.Logfile               = Log::Dispatch::FileRotate

log4perl.appender.Logfile.Threshold     = ALL
log4perl.appender.Logfile.filename      =  /<die>/failename.log
log4perl.appender.Logfile.max           = 50
log4perl.appender.Logfile.DatePattern   = yyyy-MM-dd
log4perl.appender.Logfile.TZ            = UTC
log4perl.appender.Logfile.layout        = Log::Log4perl::Layout::PatternLayout 
log4perl.appender.Logfile.layout.ConversionPattern = [%d] [%P] [%F] [%L] [%C] [%5p] %m%n
log4perl.appender.Logfile.mode          = append