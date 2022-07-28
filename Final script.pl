#!/usr/bin/perlml

no warnings "all";
use strict;
use cPanelUserConfig;

use JSON;
use utf8;

use Log::Log4perl;
use Log::Dispatch::FileRotate;
use MIME::Lite;
use Email::Simple;
use HTML::Strip;
use String::Similarity;

my $hs = HTML::Strip->new();
my $log_data;
my $log = logger();
my $body;

while (my $row = <STDIN>) {
    $body .= $row;
}

my $email = Email::Simple->new($hs->parse($body)); 
my $from_header = $email->header("From");
my $to_email = $email->header('To');
my $only_body = $email->body;

if($to_email eq '') {
    if($body =~ /To:.*<(.*)>/) {
        $to_email = $1;
    }
}

my $facility = undef;
$facility =  $email->header("Subject");
   if($facility =~ s/\s+(to|at)+(.*)//gi) {
        $facility = $2;
        $facility = trim($facility);
        $facility =~ s/\s\-\s/-/gi;
    }
$only_body = $hs->parse( $only_body );
$log_data->{raw_message} = $only_body;
$only_body =~ s/\r\n/ /gi;
$only_body =~ s/\=/ /gi;
$only_body =~ s/\s{2,}/ /gi;
my $data = parse($only_body);

#$data->{facility} = $facility;
$log_data->{parsed_data} = $data;

my $msg;
if (scalar (keys %$data) > 3) {
   $data = get_sms_email_map($data);
   $data = map_hospital_data($data);
   $msg = build_msg($data);
   $msg =~ s/\s{1,}/ /gi;
   $msg =~ s/\s\-\s/-/gi;
   # $msg =~ s/\-//gi;
   if(length($msg) > 160) {
        $log->error('ERROR message lenth exceeds 160 char '.length($msg)."message content $msg ".encode_json($data));
        $msg = substr( $msg, 0, 159 );  #truncate
        $log->info("Truncated message content $msg");
   }
   $msg = $hs->parse($msg);

   $log_data->{message_generated} = $data->{sms_text} = $msg;
    eval {
        send_email($data);
        $log->info("Success SMS email sent ".encode_json($log_data));
        $log->info("SMS sent body ".encode_json($data));
    };
    if($@) {
        $log->error("Error sending SMS".$@.'  Data '.encode_json($log_data));
        $log->error("ERROR data ".encode_json($data));
    }
} else {
    $log->error("Error while parsing data ".encode_json($log_data));
}

sub parse {
    my $raw_body = shift || undef;
    return {} unless ($raw_body);
    my $res;
    $res->{facility} = $facility;
    if(!$res->{facility} || $res->{facility} eq ''){
        if($raw_body =~ /Facility:(.*)/) {
            $res->{facility} = $1;
            $res->{facility} = trim($res->{facility});
            $res->{facility} = $hs->parse($res->{facility}) if($res->{facility});
        }
    }
    if($raw_body =~ /Patient Name:(.*)Date of/gi) {
        ($res->{firstname},$res->{lastname})  = ParseLnSFnMiNs($1);
        $res->{firstname} = $hs->parse($res->{firstname}) if($res->{firstname});
        $res->{lastname} = $hs->parse($res->{lastname})if( $res->{lastname});
    }
    if($raw_body =~ /Patient Name:(.*)Da\s+te of Birth/gi) {
        ($res->{firstname},$res->{lastname})  = ParseLnSFnMiNs($1);
        $res->{firstname} = $hs->parse($res->{firstname}) if($res->{firstname});
        $res->{lastname} = $hs->parse($res->{lastname})if( $res->{lastname});
    }
    if($raw_body =~ /Patient Name:(.*)Dat\s+e of Birth/gi) {
        ($res->{firstname},$res->{lastname})  = ParseLnSFnMiNs($1);
        $res->{firstname} = $hs->parse($res->{firstname}) if($res->{firstname});
        $res->{lastname} = $hs->parse($res->{lastname})if( $res->{lastname});
    }
    
 #parse phone
    if($raw_body =~ /Patient Phone:(.*)PCP/) {
        $res->{phone} = $1;
    }
    if(!$res->{phone} && $raw_body =~ /Patient Phone:(.*)   Attributed/) {
        $res->{phone} = $1;
    }

    $res->{phone} =~ s/[A-Za-z()-\s]+//gi;
    if ($res->{phone} =~ /(\d{3})(\d{3})(\d{4})/){
            $res->{phone} = $1.'-'.$2.'-'.$3;
    }
    
    # $res->{phone} =~ s/[A-Za-z]+//gi;
    # elsif($raw_body =~ /Patient Phone:((\d+)\d+\-\d{3}$)/){
            # $res->{phone} = $1 if(!$res->{phone});
    # }

    $res->{attribute} = undef;
    if($raw_body =~ /Attributed[\s+]?Group[\s]?:(.*).*Facility/i) {
        $res->{attribute} = $1 if(!$res->{attribute});
    } elsif($raw_body =~ /roup:(.*)Facili/) {
        $res->{attribute} = $1;
    } elsif($raw_body =~ /oup:(.*)Facili/) {
        $res->{attribute} = $1;
    } elsif($raw_body =~ /Group[\s]?(.*)Facil/gi) {
        $res->{attribute} = $1;
    } elsif($raw_body =~ /Group[\s]?(.*)Facil/gi) {
        $res->{attribute} = $1;
    }

#parse email with mutiple fail safe
    $res->{to_email} = $to_email;
    if(!$res->{to_email} || $res->{to_email} eq '') {
        if($body =~ /forwarder owner(.*)\->/g) {
            $res->{to_email} = $1;
            if($res->{to_email} =~ /\w+@[a-zA-Z_-]+?\.[a-zA-Z.]+/) {
                $res->{to_email} = $&;
            }
        }
    }

#parse email with mutiple fail safe
    if($raw_body =~ /From:.*<(.*)>/) {
        $res->{from_email} = $1;
        if($res->{from_email} =~ /\w+@[a-zA-Z_-]+?\.[a-zA-Z.]+/) {
            $res->{from_email} = $&;
        }
    } elsif ($raw_body =~ /\w+@[a-zA-Z_]+?\.[a-zA-Z.]+/ && !(defined $res->{from_email} && exists $res->{from_email})) {
        $res->{from_email} = $&;
    } elsif ($from_header =~ /\w+@[a-zA-Z_-]+?\.[a-zA-Z.]+/ && !(defined $res->{from_email} && exists $res->{from_email})) {
        $res->{from_email} = $&;
    }

    my @missing = clean($res);
    if (scalar @missing > 0) {
        foreach my $field (@missing) {
#parse name fail safe
            if(lc($field) eq 'firstname' || lc($field) eq 'lastname') {
                if($raw_body =~ /Beneficiary,(.*),/i) {
                    ($res->{firstname},$res->{lastname})  = ParseLnSFnMiNs($1);
                    $res->{firstname} = $hs->parse($res->{firstname});
                    $res->{lastname} = $hs->parse($res->{lastname});
                }
            }
#parce facility name
            if(lc($field) eq 'facility') {
                if($raw_body =~ /Emergency Department \(ED\) at (.*)\. See/) {
                    $res->{facility} = $1;
                    $res->{facility} = trim($res->{facility});
                    $res->{facility} = $hs->parse($res->{facility}) if ($res->{facility});
                }
            }
#email fail safe
            if(lc($field eq 'from_email')) {
                if($body =~ /envelope-from <(.*)>/) {
                    $res->{from_email} = $1;
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
            delete $res->{$_};
            push (@missing,$_);
        }
    }

    return (@missing);
}

sub initialNameCleanup {
	my $name = shift;
	$name =~ s/\://g;	#remove :
	$name =~ s/\>//g;	#remove :
	$name =~ s/\<//g;	#remove :
	$name =~ s/\"//g;	#remove double quotes from name, this usually present at the start and end of the value
	$name =~ s/\([^\(\)]*\)|\[[^\[\]]*\]|\{[^\{\}]*\}/ /g;	#remove any thing between () [] {}
    $name = trim($name);
	$name =~ s/[\(\{\[\*].*$/ /g;		#remove any thing that follows (,{,[,*
	return trim($name);
}

sub ParseLnSFnMiNs {
    my $name = shift ;
    initialNameCleanup($name);
    my ($lname,$fname,$minitial,$namesuffix);

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

    return (trim($fname),trim($lname),$minitial,$namesuffix);
}

sub trim {
    my $s = shift;
    return unless($s);
    $s =~ s/^\s+|\s+$//g;
    $s =~ s/\s{1,}/ /g;
    return $s;
}

sub build_msg {
    my $data = shift;
    # my $msg_b = "Your patient $data->{firstname} $data->{lastname} is currently being seen at $data->{facility}";
    my $msg_b = "$data->{firstname} $data->{lastname}, $data->{phone} is at $data->{hospital_data}->{hospital} PCP:$data->{attribute} Hospitalist is $data->{hospital_data}->{Doctor}, $data->{hospital_data}->{phone}";
    $msg_b =~ s/Visit Date.*//ig;
    $msg_b =~ s/\=//ig;
    $msg_b =~ s/See below .*//ig;
    $msg_b =~ s/, was a  dmitted to/is currently being seen at/ig;
    if(length($msg_b) > 159) {
        if(length($data->{hospital_data}->{hospital}) > 20) {
            $log->info("Truncated facility name from $data->{hospital_data}->{hospital}");
            $data->{facility_1} = substr($data->{hospital_data}->{hospital}, 0, 20 );
            $log->info("To $data->{facility_1}");
        }
        if(length($data->{attribute}) > 10) {
            $log->info("Truncated attribute name from $data->{attribute}");
            $data->{attribute} = substr($data->{attribute}, 0, 10 );
            $log->info("To $data->{attribute}");
        }
        $msg_b = "$data->{firstname} $data->{lastname}, $data->{phone} is at  $data->{facility_1} PCP:$data->{attribute} Hospitalist is $data->{hospital_data}->{Doctor}, $data->{hospital_data}->{phone}";
    }

    return $msg_b;
}

#edit the conf path here
sub logger {
    Log::Log4perl::init("/home/<full_path>/log4perl.conf");
    return Log::Log4perl->get_logger('scriptlog');
}

sub send_email {
    my $data = shift;
    my $text = $hs->parse($data->{sms_text});
    my $opt = {
        From    => 'test@kaztec.xyz',
        # To      => $data->{to_email_sms},
        To      => $data->{sms_to_email},
        #Cc      => $data->{from_email},
        Subject => 'Alert',
        Type    => 'text/plain',
        Data    => $text,
    };

    $log->info("INFO EMAIL being sent " .encode_json($opt));
    my $msg = MIME::Lite->new(%$opt);

    return $msg->send();
    # return;

}

sub get_sms_email_map {
    my $data = shift;
     my $email_map = get_email_data();
     foreach my $d_data(@$email_map){
        if($d_data->{email} eq $data->{to_email}){
            $data->{email_data} = $d_data;
            $data->{sms_to_email} = $d_data->{sms_email};
        }
     }
    # $data->{to_email} = 'xxxxxxxx@tmomail.net';
    return $data;
}

sub get_email_data {
    return [
    #add data to get email
          {
            'cellprovider' => 'T Mobile',
            'sms_email' => '000000000@tmomail.net', #here add phone_number@domain
            'email' => 'no-email@sample.com',
            'cellnumber' => 'XXX-XXX-XXXX', #replace with phone number
            'firstname' => 'FNAME',
            'lastname' => 'Lname'
          }
        ];
}


sub map_hospital_data{
    my $data = shift;
    my $h_data = get_hospital_data();
    my $similar = -1;
    foreach my $d (@$h_data) {
            $similar = similarity (lc($data->{facility}),lc($d->{Hospital}));
            if ($similar > 0.8) {
                $data->{hospital_data} = $d;
            } elsif ($similar > 0.6) {
                $data->{hospital_data} = $d unless($data->{hospital_data} || defined $data->{hospital_data});
            } elsif ($similar > 0.4 ) {
                $data->{hospital_data} = $d unless($data->{hospital_data} || defined $data->{hospital_data});
            } elsif ($similar > 0.2 ) {
                $data->{hospital_data} = $d unless($data->{hospital_data} || defined $data->{hospital_data});
            }
    }
    $log->debug("Similar hospital rank ".encode_json({similar => $similar, data=> $data}));

    return $data;

}



sub get_hospital_data {
    return  [
    #add your data hash here
    #
        {
            Hospital =>'HOSPITAL AND MEDICAL CENTER',
            Doctor => 'Jony Bravo',
            phone => '000-000-0000',
            provider =>'Verizon',
            email=>'test-some-one@email-no-exist.com',
        },
    ];
}