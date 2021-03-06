# ############################################################################
# $Id: 97_SB_SERVER.pm 12228 2016-10-01 16:43:31Z chrisd70 $
#
#  FHEM Module for Squeezebox Servers
#
# ############################################################################
#
#  used to interact with Squeezebox server
#
# ############################################################################
#
#  Written by bugster_de
#
#  Contributions from: Siggi85, Oliv06, ChrisD
#
# ############################################################################
#
#  This is absolutley open source. Please feel free to use just as you
#  like. Please note, that no warranty is given and no liability 
#  granted
#
# ############################################################################
#
#  we have the following readings
#  power            on|off
#  version          the version of the SB Server
#  serversecure     is the CLI port protected with a passowrd?
#
# ############################################################################
#
#  we have the following attributes
#  alivetimer       time frequency to set alive signals
#  maxfavorites     maximum number of favorites we handle at FHEM
#
# ############################################################################
#  we have the following internals (all UPPERCASE)
#  IP               the IP of the server
#  CLIPORT          the port for the CLI interface of the server
#
# ############################################################################
# based on 97_SB_SERVER.pm 9811 beta 0023 CD
# ############################################################################ 
package main;
use strict;
use warnings;

use IO::Socket;
use URI::Escape;
# include for using the perl ping command
use Net::Ping;
use Encode qw(decode encode);           # CD 0009 hinzugef�gt

no if $] >= 5.017011, warnings => 'experimental::smartmatch';

# this will hold the hash of hashes for all instances of SB_SERVER
my %favorites;
my $favsetstring = "favorites: ";

# this is the buffer for commands, we queue up when server is power=off
my %SB_SERVER_CmdStack;

# include this for the self-calling timer we use later on
use Time::HiRes qw(gettimeofday time);

use constant { true => 1, false => 0 };
use constant { TRUE => 1, FALSE => 0 };
use constant SB_SERVER_VERSION => '0023';

# ----------------------------------------------------------------------------
#  Initialisation routine called upon start-up of FHEM
# ----------------------------------------------------------------------------
sub SB_SERVER_Initialize( $ ) {
    my ($hash) = @_;

    require "$attr{global}{modpath}/FHEM/DevIo.pm";

# Provider
    $hash->{ReadFn}  = "SB_SERVER_Read";
    $hash->{WriteFn} = "SB_SERVER_Write";
    $hash->{ReadyFn} = "SB_SERVER_Ready";
    $hash->{Clients} = ":SB_PLAYER:";
    my %matchList= (
	"1:SB_PLAYER"   => "^SB_PLAYER:",
	);
    $hash->{MatchList} = \%matchList;

# Normal devices
    $hash->{DefFn}   = "SB_SERVER_Define";
    $hash->{UndefFn} = "SB_SERVER_Undef";
    $hash->{ShutdownFn} = "SB_SERVER_Shutdown";
    $hash->{GetFn}   = "SB_SERVER_Get";
    $hash->{SetFn}   = "SB_SERVER_Set";
    $hash->{AttrFn}  = "SB_SERVER_Attr";
    $hash->{NotifyFn}  = "SB_SERVER_Notify";

    $hash->{AttrList} = "alivetimer maxfavorites ";
    $hash->{AttrList} .= "doalivecheck:true,false ";
    $hash->{AttrList} .= "maxcmdstack ";
    $hash->{AttrList} .= "httpport ";
    $hash->{AttrList} .= "ignoredIPs ignoredMACs internalPingProtocol:icmp,tcp,udp,syn,stream,none ";   # CD 0021 none hinzugef�gt
    $hash->{AttrList} .= $readingFnAttributes;

}

# ----------------------------------------------------------------------------
#  called when defining a module
# ----------------------------------------------------------------------------
sub SB_SERVER_Define( $$ ) {
    my ($hash, $def ) = @_;
    
    #my $name = $hash->{NAME};

    Log3( $hash, 4, "SB_SERVER_Define: called" );

    # first of all close existing connections
    DevIo_CloseDev( $hash );
    
    my @a = split("[ \t][ \t]*", $def);
    
    # do we have the right number of arguments?
    if( ( @a < 3 ) || ( @a > 7 ) ) {
	Log3( $hash, 3, "SB_SERVER_Define: falsche Anzahl an Argumenten" );
	return( "wrong syntax: define <name> SB_SERVER <serverip[:cliport]>" .
		"[USER:username] [PASSWORD:password] " .                    # CD 0007 changed PASSWord to PASSWORD
		"[RCC:RCC_Name] [WOL:WOLName] [PRESENCE:PRESENCEName]" );   # CD 0007 added PRESENCE
    }

    # remove the name and our type
    my $name = shift( @a );
    shift( @a );

    # assign safe default values
    $hash->{IP} = "127.0.0.1";
    $hash->{CLIPORT}  = 9090;
    $hash->{WOLNAME} = "none";
    $hash->{PRESENCENAME} = "none";         # CD 0007
    $hash->{RCCNAME} = "none";
    $hash->{USERNAME} = "?";
    $hash->{PASSWORD} = "?";
    # parse the user spec
    foreach( @a ) {
	if( $_ =~ /^(RCC:)(.*)/ ) {
	    $hash->{RCCNAME} = $2;
	    next;
	} elsif( $_ =~ /^(WOL:)(.*)/ ) {
	    $hash->{WOLNAME} = $2;
	    next;
	} elsif( $_ =~ /^(PRESENCE:)(.*)/ ) {   # CD 0007
	    $hash->{PRESENCENAME} = $2;         # CD 0007
	    next;                               # CD 0007
	} elsif( $_ =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}):(\d{3,5})/ ) {
	    $hash->{IP} = $1;
	    $hash->{CLIPORT}  = $2;
	    next;
	} elsif( $_ =~ /^(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})/ ) {
	    $hash->{IP} = $1;
	    $hash->{CLIPORT}  = 9090;
	    next;
	} elsif( $_ =~ /^(USER:)(.*)/ ) {
	    $hash->{USERNAME} = $2;
	} elsif( $_ =~ /^(PASSWORD:)(.*)/ ) {
	    $hash->{PASSWORD} = $2;
	} else {
	    next;
	}
    }

    $hash->{LASTANSWER} = "none";

    # used for alive checking of the CLI interface
    $hash->{ALIVECHECK} = "?";

    # the status of the CLI connection (on / off)
    $hash->{CLICONNECTION} = "?";

    # preset our attributes
    if( !defined( $attr{$name}{alivetimer} ) ) {
	$attr{$name}{alivetimer} = 120;
    }

    if( !defined( $attr{$name}{doalivecheck} ) ) {
	$attr{$name}{doalivecheck} = "true";
    }

    if( !defined( $attr{$name}{maxfavorites} ) ) {
	$attr{$name}{maxfavorites} = 30;
    }

    if( !defined( $attr{$name}{maxcmdstack} ) ) {
	$attr{$name}{maxcmdstack} = 200;
    }

    # the port of the HTTP interface as needed for the coverart url
    if( !defined( $attr{$name}{httpport} ) ) {
	$attr{$name}{httpport} = "9000";
    }

    # Preset our readings if undefined
    my $tn = TimeNow();

    # server on / off
    if( !defined( $hash->{READINGS}{power}{VAL} ) ) {
	$hash->{READINGS}{power}{VAL} = "?";
	$hash->{READINGS}{power}{TIME} = $tn; 
    }

    # the server version
    if( !defined( $hash->{READINGS}{serverversion}{VAL} ) ) {
	$hash->{READINGS}{serverversion}{VAL} = "?";
	$hash->{READINGS}{serverversion}{TIME} = $tn; 
    }

    # is the CLI port secured with password?
    if( !defined( $hash->{READINGS}{serversecure}{VAL} ) ) {
	$hash->{READINGS}{serversecure}{VAL} = "?";
	$hash->{READINGS}{serversecure}{TIME} = $tn; 
    }


    # the maximum number of favorites on the server
    if( !defined( $hash->{READINGS}{favoritestotal}{VAL} ) ) {
	$hash->{READINGS}{favoritestotal}{VAL} = 0;
	$hash->{READINGS}{favoritestotal}{TIME} = $tn; 
    }

    # is a scan in progress
    if( !defined( $hash->{READINGS}{scanning}{VAL} ) ) {
	$hash->{READINGS}{scanning}{VAL} = "?";
	$hash->{READINGS}{scanning}{TIME} = $tn; 
    }

    # the scan in progress
    if( !defined( $hash->{READINGS}{scandb}{VAL} ) ) {
	$hash->{READINGS}{scandb}{VAL} = "?";
	$hash->{READINGS}{scandb}{TIME} = $tn; 
    }

    # the scan already completed
    if( !defined( $hash->{READINGS}{scanprogressdone}{VAL} ) ) {
	$hash->{READINGS}{scanprogressdone}{VAL} = "?";
	$hash->{READINGS}{scanprogressdone}{TIME} = $tn; 
    }

    # the scan already completed
    if( !defined( $hash->{READINGS}{scanprogresstotal}{VAL} ) ) {
	$hash->{READINGS}{scanprogresstotal}{VAL} = "?";
	$hash->{READINGS}{scanprogresstotal}{TIME} = $tn; 
    }

    # did the last scan fail
    if( !defined( $hash->{READINGS}{scanlastfailed}{VAL} ) ) {
	$hash->{READINGS}{scanlastfailed}{VAL} = "?";
	$hash->{READINGS}{scanlastfailed}{TIME} = $tn; 
    }

    # number of players connected to us
    if( !defined( $hash->{READINGS}{players}{VAL} ) ) {
	$hash->{READINGS}{players}{VAL} = "?";
	$hash->{READINGS}{players}{TIME} = $tn; 
    }

    # number of players connected to mysqueezebox
    if( !defined( $hash->{READINGS}{players_mysb}{VAL} ) ) {
	$hash->{READINGS}{players_mysb}{VAL} = "?";
	$hash->{READINGS}{players_mysb}{TIME} = $tn; 
    }

    # number of players connected to other servers in our network
    if( !defined( $hash->{READINGS}{players_other}{VAL} ) ) {
	$hash->{READINGS}{players_other}{VAL} = "?";
	$hash->{READINGS}{players_other}{TIME} = $tn; 
    }

    # number of albums in the database
    if( !defined( $hash->{READINGS}{db_albums}{VAL} ) ) {
	$hash->{READINGS}{db_albums}{VAL} = "?";
	$hash->{READINGS}{db_albums}{TIME} = $tn; 
    }

    # number of artists in the database
    if( !defined( $hash->{READINGS}{db_artists}{VAL} ) ) {
	$hash->{READINGS}{db_artists}{VAL} = "?";
	$hash->{READINGS}{db_artists}{TIME} = $tn; 
    }

    # number of songs in the database
    if( !defined( $hash->{READINGS}{db_songs}{VAL} ) ) {
	$hash->{READINGS}{db_songs}{VAL} = "?";
	$hash->{READINGS}{db_songs}{TIME} = $tn; 
    }

    # number of genres in the database
    if( !defined( $hash->{READINGS}{db_genres}{VAL} ) ) {
	$hash->{READINGS}{db_genres}{VAL} = "?";
	$hash->{READINGS}{db_genres}{TIME} = $tn; 
    }

    # initialize the command stack
    $SB_SERVER_CmdStack{$name}{first_n} = 0;
    $SB_SERVER_CmdStack{$name}{last_n} = 0;
    $SB_SERVER_CmdStack{$name}{cnt} = 0;
    $hash->{CMDSTACK}=0;                # CD 0007

    # assign our IO Device
    $hash->{DeviceName} = "$hash->{IP}:$hash->{CLIPORT}";

    $hash->{helper}{pingCounter}=0;     # CD 0004
    $hash->{helper}{lastPRESENCEstate}='?'; # CD 0023
    
    # CD 0009 set module version, needed for reload
    $hash->{helper}{SB_SERVER_VERSION}=SB_SERVER_VERSION;
    
    # open the IO device
    my $ret;

    # CD wait for init_done
    if ($init_done>0){
        delete($hash->{NEXT_OPEN}) if($hash->{NEXT_OPEN});          # CD 0007 reconnect immediately after modify
        # CD 0016 start
        if( $hash->{STATE} eq "opened" ) {
            DevIo_CloseDev( $hash );
            readingsSingleUpdate( $hash, "power", "?", 0 );
            $hash->{STATE}="disconnected";
        }
        # CD 0016 end
        $ret= DevIo_OpenDev($hash, 0, "SB_SERVER_DoInit" );
    }

    # do and update of the status
    # CD disabled
    #InternalTimer( gettimeofday() + 10, 
    # 		   "SB_SERVER_Alive", 
    # 		   $hash, 
    # 		   0 );

    Log3( $hash, 4, "SB_SERVER_Define: leaving" );

    return $ret;
}


# ----------------------------------------------------------------------------
#  called when deleting a module
# ----------------------------------------------------------------------------
sub SB_SERVER_Undef( $$ ) {
    my ($hash, $arg) = @_;
    my $name = $hash->{NAME};
    
    Log3( $hash, 4, "SB_SERVER_Undef: called" );
    
    # no idea what this is for. Copied from 10_TCM.pm
    # presumably to notify the clients, that the server is gone
    foreach my $d (sort keys %defs) {
	if( ( defined( $defs{$d} ) ) && 
	    ( defined( $defs{$d}{IODev} ) ) &&
	    ( $defs{$d}{IODev} == $hash ) ) {
	    delete $defs{$d}{IODev};
	}
    }
    
    # terminate the CLI session
    DevIo_SimpleWrite( $hash, "listen 0\n", 0 );
    DevIo_SimpleWrite( $hash, "exit\n", 0 );

    # close the device
    DevIo_CloseDev( $hash ); 
    
    # remove all timers we created
    RemoveInternalTimer( $hash );
    
    return( undef );
}

# ----------------------------------------------------------------------------
#  Shutdown function - called before fhem shuts down
# ----------------------------------------------------------------------------
sub SB_SERVER_Shutdown( $$ ) {
    my ($hash, $dev) = @_;
    
    Log3( $hash, 4, "SB_SERVER_Shutdown: called" );

    # terminate the CLI session
    DevIo_SimpleWrite( $hash, "listen 0\n", 0 );
    DevIo_SimpleWrite( $hash, "exit\n", 0 );

    # close the device
    DevIo_CloseDev( $hash ); 

    # remove all timers we created
    RemoveInternalTimer( $hash );

    return( undef );
}


# ----------------------------------------------------------------------------
#  ReadyFn - called when?
# ----------------------------------------------------------------------------
sub SB_SERVER_Ready( $ ) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    #Log3( $hash, 4, "SB_SERVER_Ready: called" );

    # check for bad/missing password
    if (defined($hash->{helper}{SB_SERVER_LMS_Status})) {
        if (time()-($hash->{helper}{SB_SERVER_LMS_Status})<2) {
            if( ( $hash->{USERNAME} ne "?" ) && 
                ( $hash->{PASSWORD} ne "?" ) ) {
                $hash->{LASTANSWER}='invalid username or password ?';
                Log( 1, "SB_SERVER($name): invalid username or password ?" );
            } else {
                $hash->{LASTANSWER}='missing username and password ?';
                Log( 1, "SB_SERVER($name): missing username and password ?" );
            }
            $hash->{NEXT_OPEN}=time()+60;
        }
        delete($hash->{helper}{SB_SERVER_LMS_Status});
    }
    
    # we need to re-open the device
    if( $hash->{STATE} eq "disconnected" ) {
        if( ( ReadingsVal( $name, "power", "on" ) eq "on" ) ||
            ( ReadingsVal( $name, "power", "on" ) eq "?" ) ) {
            # obviously the first we realize the Server is off
            # clean up first
            RemoveInternalTimer( $hash );
            readingsSingleUpdate( $hash, "power", "off", 1 );
            
            $hash->{CLICONNECTION} = "off";                         # CD 0007

            # and signal to our clients
            SB_SERVER_Broadcast( $hash, "SERVER",  "OFF" );
        }
        # CD added init_done
        if ($init_done>0) {
            # CD 0007 faster reconnect after WOL, use PRESENCE
            my $reconnect=0;
            if(defined($hash->{helper}{WOLFastReconnectUntil})) {
                $hash->{TIMEOUT}=1;
                if (time() > $hash->{helper}{WOLFastReconnectNext}) {
                    delete($hash->{NEXT_OPEN}) if($hash->{NEXT_OPEN});
                    $hash->{helper}{WOLFastReconnectNext}=time()+15;
                    $reconnect=1;
                }
                if (time() > $hash->{helper}{WOLFastReconnectUntil}) {
                    delete($hash->{TIMEOUT});
                    delete($hash->{helper}{WOLFastReconnectUntil});
                    delete($hash->{helper}{WOLFastReconnectNext});
                }
            }
            if( ReadingsVal( $hash->{PRESENCENAME}, "state", "present" ) eq "present" ) {
                $reconnect=1;
            }
            if ($reconnect==1) {
                return( DevIo_OpenDev( $hash, 1, "SB_SERVER_DoInit") );
            } else {
                return undef;
            }
        } else {
            return undef;
        }
    }
}

# ----------------------------------------------------------------------------
#  Get functions 
# ----------------------------------------------------------------------------
sub SB_SERVER_Get( $@ ) {
    my ($hash, @a) = @_;
    my $name = $hash->{NAME};
    
    Log3( $hash, 4, "SB_SERVER_Get: called" );

    if( @a != 2 ) {
	return( "\"get $name\" needs one parameter" );
    }

    return( "?" );
}


# ----------------------------------------------------------------------------
#  Attr functions 
# ----------------------------------------------------------------------------
sub SB_SERVER_Attr( @ ) {
    my $cmd = shift( @_ );
    my $name = shift( @_ );
    my $hash = $defs{$name};
    my @args = @_;

    Log( 4, "SB_SERVER_Attr($name): called with @args" );

    if( $cmd eq "set" ) {
        if( $args[ 0 ] eq "alivetimer" ) {
            # CD 0021 start
            RemoveInternalTimer( "SB_SERVER_Alive:$name");
            InternalTimer( gettimeofday() + $args[ 1 ],
                       "SB_SERVER_tcb_Alive",
                       "SB_SERVER_Alive:$name", 
                       0 );
            # CD 0021 end
        }
        # CD 0015 bei �nderung des Ports diesen an Clients schicken
        if( $args[ 0 ] eq "httpport" ) {
            SB_SERVER_Broadcast( $hash, "SERVER", 
                     "IP " . $hash->{IP} . ":" .
                     $args[ 1 ] );
        }
    }
}


# ----------------------------------------------------------------------------
#  Set function
# ----------------------------------------------------------------------------
sub SB_SERVER_Set( $@ ) {
    my ($hash, @a) = @_;
    my $name = $hash->{NAME};

    Log( 4, "SB_SERVER_Set($name): called" );

    if( @a < 2 ) {
	return( "at least one parameter is needed" ) ;
    }

    $name = shift( @a );
    my $cmd = shift( @a );

    if( $cmd eq "?" ) {
	# this one should give us a drop down list
	my $res = "Unknown argument ?, choose one of " . 
	    "on renew:noArg abort:noArg cliraw statusRequest:noArg ";
	$res .= "rescan:full,playlists ";
    #$res .= "addToFHEMUpdate:noArg removeFromFHEMUpdate:noArg";  # CD 0019

	return( $res );

    } elsif( $cmd eq "on" ) {
	if( ReadingsVal( $name, "power", "off" ) eq "off" ) {
	    # the server is off, try to reactivate it
	    if( $hash->{WOLNAME} ne "none" ) {
		fhem( "set $hash->{WOLNAME} on" );
        $hash->{helper}{WOLFastReconnectUntil}=time()+120;   # CD 0007
        $hash->{helper}{WOLFastReconnectNext}=time()+30;    # CD 0007
	    }
	    if( $hash->{RCCNAME} ne "none" ) {
		fhem( "set $hash->{RCCNAME} on" );
	    }
	}

    } elsif( $cmd eq "renew" ) {
	Log3( $hash, 5, "SB_SERVER_Set: renew" );
	DevIo_SimpleWrite( $hash, "listen 1\n", 0 );
	
    } elsif( $cmd eq "abort" ) {
	DevIo_SimpleWrite( $hash, "listen 0\n", 0 );
	
    } elsif( $cmd eq "statusRequest" ) {
	Log3( $hash, 5, "SB_SERVER_Set: statusRequest" );
	DevIo_SimpleWrite( $hash, "version ?\n", 0 );
	DevIo_SimpleWrite( $hash, "serverstatus 0 200\n", 0 );
	DevIo_SimpleWrite( $hash, "favorites items 0 " .
			   AttrVal( $name, "maxfavorites", 100 ) . " want_url:1\n",      # CD 0009 url mit abfragen
			   0 );
	DevIo_SimpleWrite( $hash, "playlists 0 200\n", 0 );
    DevIo_SimpleWrite( $hash, "alarm playlists 0 300\n", 0 );               # CD 0011
	
    } elsif( $cmd eq "cliraw" ) {
        # write raw messages to the CLI interface per player
        my $v = join( " ", @a );
        $v .= "\n";	
        Log3( $hash, 5, "SB_SERVER_Set: cliraw: $v " ); 
        DevIo_SimpleWrite( $hash, $v, 0 ); # CD 0016 IOWrite in DevIo_SimpleWrite ge�ndert
    } elsif( $cmd eq "rescan" ) {
        DevIo_SimpleWrite( $hash, $cmd . " " . $a[ 0 ] . "\n", 0 );     # CD 0016 IOWrite in DevIo_SimpleWrite ge�ndert
    # CD 0018 start
    #} elsif( $cmd eq "addToFHEMUpdate" ) {
    #   fhem("update add https://raw.githubusercontent.com/ChrisD70/FHEM-Modules/master/autoupdate/sb/controls_squeezebox.txt");
    #} elsif( $cmd eq "removeFromFHEMUpdate" ) {
    #    fhem("update delete https://raw.githubusercontent.com/ChrisD70/FHEM-Modules/master/autoupdate/sb/controls_squeezebox.txt");
    # CD 0018 end
    } else {
	;
    }
    
    return( undef );
}


# ----------------------------------------------------------------------------
# Read
# called from the global loop, when the select for hash->{FD} reports data
# ----------------------------------------------------------------------------
sub SB_SERVER_Read( $ ) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    #my $start = time;   # CD 0019
    
    Log3( $hash, 4, "SB_SERVER_Read($name): called" );
    Log3( $hash, 5, "+++++++++++++++++++++++++++++++++++++++++++++++++++++" );
    Log3( $hash, 5, "New Squeezebox Server Read cycle starts here" );
    Log3( $hash, 5, "+++++++++++++++++++++++++++++++++++++++++++++++++++++" );

    my $buf = DevIo_SimpleRead( $hash );

    if( !defined( $buf ) ) {
        return( "" );
    }

    # if we have data, the server is on again
    if( ReadingsVal( $name, "power", "off" ) ne "on" ) {
        readingsSingleUpdate( $hash, "power", "on", 1 );
        if( defined( $SB_SERVER_CmdStack{$name}{cnt} ) ) {
            my $maxmsg = $SB_SERVER_CmdStack{$name}{cnt};
            my $out;
            for( my $n = 0; $n <= $maxmsg; $n++ ) {
                $out = SB_SERVER_CMDStackPop( $hash );
                if( $out ne "empty" ) {
                    DevIo_SimpleWrite( $hash, $out , 0 );
                }	    
            }
        }
        #Log3( $hash, 5, "SB_SERVER_Read($name): please implement the " .   # CD 0009 Meldung deaktiviert
        #      "sending of the CMDStack." );                                # CD 0009 Meldung deaktiviert
    }

    #my $t1 = time;   # CD 0020

    # if there are remains from the last time, append them now
    $buf = $hash->{PARTIAL} . $buf;

    $buf = uri_unescape( $buf );
    Log3( $hash, 6, "SB_SERVER_Read: the buf: $buf" );  # CD TEST 6

    # CD 0021 start - Server lebt noch, alivetimer neu starten
    RemoveInternalTimer( "SB_SERVER_Alive:$name");
    InternalTimer( gettimeofday() + 
               AttrVal( $name, "alivetimer", 10 ),
               "SB_SERVER_tcb_Alive",
               "SB_SERVER_Alive:$name", 
               0 );
    # CD 0021 end
    
    #my $t2 = time;   # CD 0020

    # if we have received multiline commands, they are split by \n
    my @cmds = split( "\n", $buf );

    # check for last element in string
    my $lastchr = substr( $buf, -1, 1 );
    if( $lastchr ne "\n" ) {
        #ups, the return doesn't seem to be complete
        $hash->{PARTIAL} = $cmds[ $#cmds ];
        # and remove the last element
        pop( @cmds );
        Log3( $hash, 5, "SB_SERVER_Read: uncomplete command received" );
    } else {
        Log3( $hash, 5, "SB_SERVER_Read: complete command received" );
        $hash->{PARTIAL} = "";
    }

    #my $t3 = time;   # CD 0020

    # and dispatch the rest
    foreach( @cmds ) {
        #my $t31=time;   # CD 0020
        # double check complete line
        my $lastchar = substr( $_, -1);
        SB_SERVER_DispatchCommandLine( $hash, $_  );
        # CD 0020 start
        #if((time-$t31)>0.3) {
        #    Log3($hash,0,"SB_SERVER_Read($name), time:".int((time-$t31)*1000)." cmd: ".$_);
        #}
        # CD 0020 end
    }

    #my $t4 = time;   # CD 0020

    # CD 0009 check for reload of newer version
    $hash->{helper}{SB_SERVER_VERSION}=0 if (!defined($hash->{helper}{SB_SERVER_VERSION}));     # CD 0012
    if ($hash->{helper}{SB_SERVER_VERSION} ne SB_SERVER_VERSION)
    {
        Log3( $hash, 1,"SB_SERVER_Read: SB_SERVER_VERSION changed from ".$hash->{helper}{SB_SERVER_VERSION}." to ".SB_SERVER_VERSION);  # CD 0012
        $hash->{helper}{SB_SERVER_VERSION}=SB_SERVER_VERSION;
        DevIo_SimpleWrite( $hash, "version ?\n", 0 );
        DevIo_SimpleWrite( $hash, "serverstatus 0 200\n", 0 );
        DevIo_SimpleWrite( $hash, "favorites items 0 " . 
                   AttrVal( $name, "maxfavorites", 100 ) . " want_url:1\n",        # CD 0009 url mit abfragen
                   0 );
        DevIo_SimpleWrite( $hash, "playlists 0 200\n", 0 );
    }
    # CD 0009 end

    Log3( $hash, 5, "+++++++++++++++++++++++++++++++++++++++++++++++++++++" );
    Log3( $hash, 5, "Squeezebox Server Read cycle ends here" );
    Log3( $hash, 5, "+++++++++++++++++++++++++++++++++++++++++++++++++++++" );
    
    # CD 0019 start
    #my $end   = time;
    #if (($end - $start)>1) {
    #    Log3( $hash, 0, "SB_SERVER_Read($name), times: ".int(($t1 - $start)*1000)." ".int(($t2 - $t1)*1000)." ".int(($t3 - $t2)*1000)." ".int(($t4 - $t3)*1000)." ".int(($end - $start)*1000)." nCmds: ".$#cmds );
    #}
    # CD 0019 end
    
    return( undef );
}


# ----------------------------------------------------------------------------
# called by the clients to send data
# ----------------------------------------------------------------------------
sub SB_SERVER_Write( $$$ ) {
    my ( $hash, $fn, $msg ) = @_;
    my $name = $hash->{NAME};

    Log3( $hash, 4, "SB_SERVER_Write($name): called with FN:$fn" ); # unless($fn=~m/\?/);  # CD TEST 4

    if( !defined( $fn ) ) {
	return( undef );
    }

    if( defined( $msg ) ) {
	Log3( $hash, 4, "SB_SERVER_Write: MSG:$msg" );
    }

    # CD 0012 fhemrelay Meldungen nicht an den LMS schicken sondern direkt an Dispatch �bergeben
    if($fn =~ m/fhemrelay/) {
    	SB_SERVER_DispatchCommandLine( $hash, $fn );
        return( undef );
    }
    
    if( ReadingsVal( $name, "serversecure", "0" ) eq "1" ) {
	if( ( $hash->{USERNAME} ne "?" ) && ( $hash->{PASSWORD} ne "?" ) ) {
	    # we need to send username and password first
	} else {
	    my $retmsg = "SB_SERVER_Write: Server needs username and " . 
		"password but you did not specify those. No sending";	
	    Log3( $hash, 1, $retmsg );
	    return( $retmsg );
	}
    }

    if( ReadingsVal( $name, "power", "on" ) eq "on" ) {
	DevIo_SimpleWrite( $hash, "$fn", 0 );
    } else {
	# we are off, so save the command for later
	# if maxcmdstack is 0, the function is turned off
	if( AttrVal( $name, "maxcmdstack", 100 ) > 0 ) {
	    SB_SERVER_CMDStackPush( $hash, $fn );
	}
    }

}


# ----------------------------------------------------------------------------
#  Initialisation of the CLI connection
# ----------------------------------------------------------------------------
sub SB_SERVER_DoInit( $ ) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    Log3( $hash, 4, "SB_SERVER_DoInit($name): called" );

    if( !$hash->{TCPDev} ) {
        Log3( $hash, 2, "SB_SERVER_DoInit: no TCPDev available?" );     # CD 0009 level 5->2
        DevIo_CloseDev( $hash ); 
    }

    Log3( $hash, 3, "SB_SERVER_DoInit($name): STATE: " . $hash->{STATE} . " power: ". ReadingsVal( $name, "power", "X" ));    # CD 0009 level 2 -> 3

    if( $hash->{STATE} eq "disconnected" ) {
        # server is off after FHEM start, broadcast to clients
        if( ( ReadingsVal( $name, "power", "on" ) eq "on" ) ||
            ( ReadingsVal( $name, "power", "on" ) eq "?" ) ) {
            Log3( $hash, 3, "SB_SERVER_DoInit($name): " .                   # CD 0009 level 2 -> 3
              "SB-Server in hibernate / suspend?." );

              # obviously the first we realize the Server is off
            readingsSingleUpdate( $hash, "power", "off", 1 );

            # and signal to our clients
            SB_SERVER_Broadcast( $hash, "SERVER",  "OFF" );
            SB_SERVER_Broadcast( $hash, "SERVER", 
                     "IP " . $hash->{IP} . ":" .
                     AttrVal( $name, "httpport", "9000" ) );
        }
        return( 1 );
    } elsif( $hash->{STATE} eq "opened" ) {
        $hash->{ALIVECHECK} = "?";
        $hash->{CLICONNECTION} = "on";
        if( ( ReadingsVal( $name, "power", "on" ) eq "off" ) ||
            ( ReadingsVal( $name, "power", "on" ) eq "?" ) ) {
            Log3( $hash, 3, "SB_SERVER_DoInit($name): " .                   # CD 0009 level 2 -> 3
              "SB-Server is back again." );

            # CD 0007 cleanup
            if(defined($hash->{helper}{WOLFastReconnectUntil})) {
                    delete($hash->{TIMEOUT});
                    delete($hash->{helper}{WOLFastReconnectUntil});
                    delete($hash->{helper}{WOLFastReconnectNext});
            }
            $hash->{helper}{pingCounter}=0;                                 # CD 0007
            
            SB_SERVER_Broadcast( $hash, "SERVER", 
                     "IP " . $hash->{IP} . ":" .
                     AttrVal( $name, "httpport", "9000" ) );
            $hash->{helper}{doBroadcast}=1;                                 # CD 0007

            SB_SERVER_LMS_Status( $hash );
            if( AttrVal( $name, "doalivecheck", "false" ) eq "false" ) {
            readingsSingleUpdate( $hash, "power", "on", 1 );
            #SB_SERVER_Broadcast( $hash, "SERVER",  "ON" );                 # CD 0007
            return( 0 );

            } elsif( AttrVal( $name, "doalivecheck", "false" ) eq "true" ) {
            # start the alive checking mechanism
            # CD 0020 SB_SERVER_tcb_Alive verwenden
            RemoveInternalTimer( "SB_SERVER_Alive:$name");
            InternalTimer( gettimeofday() + 
                       AttrVal( $name, "alivetimer", 10 ),
                       "SB_SERVER_tcb_Alive",
                       "SB_SERVER_Alive:$name", 
                       0 );
            return( 0 );

            } else {
            Log3( $hash, 2, "SB_SERVER_DoInit: doalivecheck has " . 
                  "wrong value" );
            return( 1 );
            }
            
        }
	    
    } else {
	# what the f...
	Log3( $hash, 2, "SB_SERVER_DoInit: unclear status reported" );
	return( 1 );
    }

	#Log3( $hash, 3, "SB_SERVER_DoInit: something went wrong!" );        # CD 0008 nur f�r Testzwecke 0009 deaktiviert
    #return(0);                                                          # CD 0008 nur f�r Testzwecke 0009 deaktiviert
    return( 1 );
}


# ----------------------------------------------------------------------------
#  Dispatch every single line of commands
# ----------------------------------------------------------------------------
sub SB_SERVER_DispatchCommandLine( $$ ) {
    my ( $hash, $buf ) = @_;
    my $name = $hash->{NAME};

    Log3( $hash, 4, "SB_SERVER_DispatchCommandLine($name): Line:$buf..." );

    # try to extract the first answer to the SPACE
    my $indx = index( $buf, " " );
    my $id1  = substr( $buf, 0, $indx );

    # is the first return value a player ID? 
    # Player ID is MAC adress, hence : included
    my @id = split( ":", $id1 );

    if( @id > 1 ) {
	# we have received a return for a dedicated player

	# create the fhem specific unique id
	my $playerid = join( "", @id );
	Log3( $hash, 5, "SB_SERVER_DispatchCommandLine: fhem-id: $playerid" );
	
	# create the commands
	my $cmds = substr( $buf, $indx + 1 );
	Log3( $hash, 5, "SB_SERVER__DispatchCommandLine: commands: $cmds" );
	Dispatch( $hash, "SB_PLAYER:$playerid:$cmds", undef );

    } else {
	# that is a server specific command
	SB_SERVER_ParseCmds( $hash, $buf );
    }

    return( undef );
}


# ----------------------------------------------------------------------------
#  parse the server answers that are not intended for players
# ----------------------------------------------------------------------------
sub SB_SERVER_ParseCmds( $$ ) {
    my ( $hash, $instr ) = @_;
    my $name = $hash->{NAME};

    Log3( $hash, 4, "SB_SERVER_ParseCmds($name): called" );

    my @args = split( " ", $instr );

    $hash->{LASTANSWER} = "@args";

    my $cmd = shift( @args );

    # CD 0007 start
    if (defined($hash->{helper}{doBroadcast})) {
	    SB_SERVER_Broadcast( $hash, "SERVER", "ON" );
	    SB_SERVER_Broadcast( $hash, "SERVER", 
				 "IP " . $hash->{IP} . ":" .
				 AttrVal( $name, "httpport", "9000" ) );
        delete ($hash->{helper}{doBroadcast});
    }
    # CD 0007 end
    
    if( $cmd eq "version" ) {
	readingsSingleUpdate( $hash, "serverversion", $args[ 1 ], 0 );

	if( ReadingsVal( $name, "power", "off" ) eq "off" ) {
	    # that also means the server returned from being away
	    readingsSingleUpdate( $hash, "power", "on", 1 );
	    # signal our players
	    SB_SERVER_Broadcast( $hash, "SERVER", "ON" );
	    SB_SERVER_Broadcast( $hash, "SERVER", 
				 "IP " . $hash->{IP} . ":" .
				 AttrVal( $name, "httpport", "9000" ) );
	}

    } elsif( $cmd eq "pref" ) {
	if( $args[ 0 ] eq "authorize" ) {
	    readingsSingleUpdate( $hash, "serversecure", $args[ 1 ], 0 );
	    if( $args[ 1 ] eq "1" ) {
		# username and password is required
        # CD 0007 zu sp�t, login muss als erstes gesendet werden, andernfalls bricht der Server die Verbindung sofort ab
		if( ( $hash->{USERNAME} ne "?" ) && 
		    ( $hash->{PASSWORD} ne "?" ) ) {
		    DevIo_SimpleWrite( $hash, "login " . 
				       $hash->{USERNAME} . " " . 
				       $hash->{PASSWORD} . "\n", 
				       0 );
		} else {
		    Log3( $hash, 3, "SB_SERVER_ParseCmds($name): login " . 
			  "required but no username and password specified" );
		}
		# next step is to wait for the answer of the LMS server
	    } elsif( $args[ 1 ] eq "0" ) {
		# no username password required, go ahead directly
		#SB_SERVER_LMS_Status( $hash );
	    } else {
		Log3( $hash, 3, "SB_SERVER_ParseCmds($name): unkown " . 
		      "result for authorize received. Should be 0 or 1" );
	    }		
	}

    } elsif( $cmd eq "login" ) {
	if( ( $args[ 1 ] eq $hash->{USERNAME} ) && 
	    ( $args[ 2 ] eq "******" ) ) {
	    # login has been succesful, go ahead
	    SB_SERVER_LMS_Status( $hash );
	}
	

    } elsif( $cmd eq "fhemalivecheck" ) {
	$hash->{ALIVECHECK} = "received";
	Log3( $hash, 4, "SB_SERVER_ParseCmds($name): alivecheck received" );

    } elsif( $cmd eq "favorites" ) {
	if( $args[ 0 ] eq "changed" ) {
	    Log3( $hash, 4, "SB_SERVER_ParseCmds($name): favorites changed" );
	    # we need to trigger the favorites update here
	    DevIo_SimpleWrite( $hash, "favorites items 0 " . 
			       AttrVal( $name, "maxfavorites", 100 ) . 
			       " want_url:1\n", 0 );           # CD 0009 url mit abfragen
        DevIo_SimpleWrite( $hash, "alarm playlists 0 300\n", 0 );       # CD 0011
	} elsif( $args[ 0 ] eq "items" ) {
	    Log3( $hash, 4, "SB_SERVER_ParseCmds($name): favorites items" );
	    # the response to our query of the favorites
	    SB_SERVER_FavoritesParse( $hash, join( " ", @args ) );	    
	} else {
	}

    } elsif( $cmd eq "serverstatus" ) {
	Log3( $hash, 4, "SB_SERVER_ParseCmds($name): server status" );
	SB_SERVER_ParseServerStatus( $hash, \@args );

    } elsif( $cmd eq "playlists" ) {
        Log3( $hash, 4, "SB_SERVER_ParseCmds($name): playlists" );
        # CD 0004 Playlisten neu anfragen bei �nderung
        if(($args[0] eq "rename")||($args[0] eq "delete")) {
            DevIo_SimpleWrite( $hash, "playlists 0 200\n", 0 );
            DevIo_SimpleWrite( $hash, "alarm playlists 0 300\n", 0 );   # CD 0011
        } else {
            SB_SERVER_ParseServerPlaylists( $hash, \@args );
        }
    } elsif( $cmd eq "client" ) {

    # CD 0011 start
    } elsif( $cmd eq "alarm" ) {
        if( $args[0] eq "playlists" ) {
            SB_SERVER_ParseServerAlarmPlaylists( $hash, \@args );
        }
    # CD 0011 end
    # CD 0016 start
    } elsif( $cmd eq "rescan" ) {
        if( $args[0] eq "done" ) {
        	DevIo_SimpleWrite( $hash, "serverstatus 0 200\n", 0 );
        }
    # CD 0016 end
    } else {
	# unkown
    }
}

# CD 0020 start
sub SB_SERVER_tcb_Alive($) {
    my($in ) = shift;
    my(undef,$name) = split(':',$in);
    my $hash = $defs{$name};

    #Log 0,"SB_SERVER_tcb_Alive";
    SB_SERVER_Alive($hash);
}
# CD 0020 end

# ----------------------------------------------------------------------------
#  Alivecheck of the server
# ----------------------------------------------------------------------------
sub SB_SERVER_Alive( $ ) {
    my ($hash) = @_;
    my $name = $hash->{NAME};

    # CD 0004 set default to off
    #my $rccstatus = "on";
    #my $pingstatus = "on";
    my $rccstatus = "off";
    my $pingstatus = "off";
    my $nexttime = gettimeofday() + AttrVal( $name, "alivetimer", 120 );

    Log3( $hash, 4, "SB_SERVER_Alive($name): called" );                     # CD 0006 changed log level from 4 to 2 # CD 0009 level 2->3 # CD 0014 level -> 4

    if( AttrVal( $name, "doalivecheck", "false" ) eq "false" ) {
        Log3( $hash, 5, "SB_SERVER_Alive($name): alivechecking is off" );
        $rccstatus  = "on";
        $pingstatus = "on";
        $hash->{helper}{pingCounter}=0;                                     # CD 0004
    } else {
        # check via the RCC element
        if( $hash->{RCCNAME} ne "none" ) {
            # an RCC element has been given as argument
            $rccstatus = ReadingsVal( $hash->{RCCNAME}, "state", "off" );
        }

        # CD 0007 start
        if (($hash->{PRESENCENAME} ne "none")
            && defined($defs{$hash->{PRESENCENAME}})
            && defined($defs{$hash->{PRESENCENAME}}->{TIMEOUT_NORMAL})
            && (($defs{$hash->{PRESENCENAME}}->{TIMEOUT_NORMAL}) < AttrVal( $name, "alivetimer", 30 ))) {
            Log3( $hash, 4,"SB_SERVER_Alive($name): using $hash->{PRESENCENAME}");                      # CD 0009 level 2->4
            if( ReadingsVal( $hash->{PRESENCENAME}, "state", "absent" ) eq "present" ) {
                $pingstatus = "on";
                $hash->{helper}{pingCounter}=0;
            } else {
                $pingstatus = "off";
                $hash->{helper}{pingCounter}=$hash->{helper}{pingCounter}+1;
                $nexttime = gettimeofday() + 15;
            }
        } else {
        # CD 0007 end
            # CD 0021 start
            my $ipp=AttrVal($name, "internalPingProtocol", "tcp" );
            if($ipp eq "none") {
                if ($hash->{STATE} eq "disconnected") {
                    $pingstatus = "off";
                    $hash->{helper}{pingCounter}=3;
                } else {
                    $pingstatus = "on";
                    $hash->{helper}{pingCounter}=0;
                }
            } else {
            # CD 0021 end
                Log3( $hash, 4,"SB_SERVER_Alive($name): using internal ping");                              # CD 0007 # CD 0009 level 2->4
                # check via ping
                my $p;
                # CD 0017 eval hinzugef�gt, Absturz auf FritzBox, bei Fehler annehmen dass Host verf�gbar ist, internalPingProtocol hinzugef�gt
                
                eval { $p = Net::Ping->new( $ipp ); };
                if($@) {
                    Log3( $hash,1,"SB_SERVER_Alive($name): internal ping failed with $@");
                    $pingstatus = "on";
                    $hash->{helper}{pingCounter}=0;
                } else {
                    if( $p->ping( $hash->{IP}, 2 ) ) {
                        $pingstatus = "on";
                        $hash->{helper}{pingCounter}=0;                                 # CD 0004
                    } else {
                        $pingstatus = "off";
                        $hash->{helper}{pingCounter}=$hash->{helper}{pingCounter}+1;    # CD 0004
                    }
                    # close our ping mechanism again
                    $p->close( );
                }
            } # CD 0021
        } # CD 0007
        Log3( $hash, 5, "SB_SERVER_Alive($name): " .            # CD Test 5
              "RCC:" . $rccstatus . " Ping:" . $pingstatus );               # CD 0006 changed log level from 5 to 2 # CD 0009 level 2->3 # CD 0014 level -> 5
    }

    # set the status of the server accordingly
    # CD 0004 added sensitivity to ping
#    if( ( $rccstatus eq "on" ) || ( $pingstatus eq "on" ) ) {
    if( ( $rccstatus eq "on" ) || ( $hash->{helper}{pingCounter}<3 ) ) {

        # the server is reachable
        if( ReadingsVal( $name, "power", "on" ) eq "off" ) {
            # the first time we see the server being on
            Log3( $hash, 3, "SB_SERVER_Alive($name): " .    # CD 0004 changed log level from 5 to 2 # CD 0009 level 2->3
              "SB-Server is back again." );
            # first time we realized server is away
            if( $hash->{STATE} eq "disconnected" ) {
                delete($hash->{NEXT_OPEN}) if($hash->{NEXT_OPEN});                  # CD 0007 remove delay for reconnect
                DevIo_OpenDev( $hash, 1, "SB_SERVER_DoInit" );
            }

            readingsSingleUpdate( $hash, "power", "on", 1 );

            $hash->{ALIVECHECK} = "?";
            $hash->{CLICONNECTION} = "off";

            # quicker update to capture CLI connection faster
            $nexttime = gettimeofday() + 10;
        } else {                                                                    # CD 0005
            # check the CLI connection (sub-state)
            if( $hash->{ALIVECHECK} eq "waiting" ) {
                # ups, we did not receive any answer in the last minutes
                # SB Server potentially dead or shut-down
                Log3( $hash, 3, "SB_SERVER_Alive($name): overrun SB-Server dead." );    # CD 0004 changed log level from 5 to 2 # CD 0009 level 2->3

                $hash->{CLICONNECTION} = "off";

                # signal that to our clients
                SB_SERVER_Broadcast( $hash, "SERVER",  "OFF" );

                # close the device
                # CD 0007 use DevIo_Disconnected instead of DevIo_CloseDev
                #DevIo_CloseDev( $hash ); 
                DevIo_Disconnected( $hash ); 
                $hash->{helper}{pingCounter}=9999;                                 # CD 0007

                # CD 0000 start - exit infinite loop after socket has been closed
                $hash->{ALIVECHECK} = "?";
                $hash->{STATE}="disconnected";
                # CD 0005 line above does not work (on Linux), fix:
                # CD 0006 DevIo_setStates requires v7099 of DevIo.pm, replaced with SB_SERVER_setStates
                SB_SERVER_setStates($hash, "disconnected");
                
                readingsSingleUpdate( $hash, "power", "off", 1 );
                # test: clear stack ?
                $SB_SERVER_CmdStack{$name}{last_n} = 0;
                $SB_SERVER_CmdStack{$name}{first_n} = 0;
                $SB_SERVER_CmdStack{$name}{cnt} = 0;
                # CD end

                # remove all timers we created
                RemoveInternalTimer( $hash );
            } else {
                if( $hash->{CLICONNECTION} eq "off" ) {
                    # signal that to our clients
                    # to be revisited, should only be sent after CLI established
                    #SB_SERVER_Broadcast( $hash, "SERVER",  "ON" );             # CD 0007 disabled, wait for SB_SERVER_LMS_Status
                    SB_SERVER_LMS_Status( $hash );
                }
                
                $hash->{CLICONNECTION} = "on";

                # just send something to the SB-Server. It will echo it
                # if we receive the echo, the server is still alive
                $hash->{ALIVECHECK} = "waiting";
                DevIo_SimpleWrite( $hash, "fhemalivecheck\n", 0 );
            }
        }
    } elsif( ( $rccstatus eq "off" ) && ( $pingstatus eq "off" ) ) {
        if( ReadingsVal( $name, "power", "on" ) eq "on" ) {
            # the first time we realize the server is off
            Log3( $hash, 3, "SB_SERVER_Alive($name): " .    # CD 0004 changed log level from 5 to 2 # CD 0009 level 2->3
              "SB-Server in hibernate / suspend?." );

            # first time we realized server is away
            $hash->{CLICONNECTION} = "off";
            readingsSingleUpdate( $hash, "power", "off", 1 );
            $hash->{ALIVECHECK} = "?";

            # signal that to our clients
            SB_SERVER_Broadcast( $hash, "SERVER",  "OFF" );

            # close the device
            # CD 0007 use DevIo_Disconnected instead of DevIo_CloseDev
            #DevIo_CloseDev( $hash ); 
            DevIo_Disconnected( $hash ); 
            $hash->{helper}{pingCounter}=9999;                                 # CD 0007
            # CD 0004 set STATE, needed for reconnect
            $hash->{STATE}="disconnected";
            # CD 0005 line above does not work (on Linux), fix:
            # CD 0006 DevIo_setStates requires v7099 of DevIo.pm, replaced with SB_SERVER_setStates
            SB_SERVER_setStates($hash, "disconnected");
            # remove all timers we created
            RemoveInternalTimer( $hash );
        }
    } else {
        # we shouldn't end up here
        Log3( $hash, 5, "SB_SERVER_Alive($name): funny server status " . 
              "received. Ping=" . $pingstatus . " RCC=" . $rccstatus );
    }

    # do an update of the status
    # CD 0020 SB_SERVER_tcb_Alive verwenden
    RemoveInternalTimer( "SB_SERVER_Alive:$name");
    InternalTimer( $nexttime, 
           "SB_SERVER_tcb_Alive",
           "SB_SERVER_Alive:$name", 
		   0 );
}


# ----------------------------------------------------------------------------
#  Broadcast a message to all clients
# ----------------------------------------------------------------------------
sub SB_SERVER_Broadcast( $$@ ) {
    my( $hash, $cmd, $msg, $bin ) = @_;
    my $name = $hash->{NAME};
    my $iodevhash;

    Log3( $hash, 4, "SB_SERVER_Broadcast($name): called with $cmd - $msg" );

    if( !defined( $bin ) ) {
	$bin = 0;
    }

    foreach my $mydev ( keys %defs ) {
	# the hash to the IODev as defined at the client
	if( defined( $defs{$mydev}{IODev} ) ) {
	    $iodevhash = $defs{$mydev}{IODev};
	} else {
	    $iodevhash = undef;
	}

	if( defined( $iodevhash ) ) {
	    if( ( defined( $defs{$mydev}{TYPE} ) ) && 
		( defined( $iodevhash->{NAME} ) ) ){

		if( ( $defs{$mydev}{TYPE} eq "SB_PLAYER" ) &&
		    ( $iodevhash->{NAME} eq $name ) ) {
		    # we found a valid entry
		    my $clienthash = $defs{$mydev};
		    my $namebuf = $clienthash->{NAME};
		    
		    SB_PLAYER_RecBroadcast( $clienthash, $cmd, $msg, $bin );
		}
	    }
	} 
    }
    
    return;
}


# ----------------------------------------------------------------------------
#  Handle the return for a serverstatus query
# ----------------------------------------------------------------------------
sub SB_SERVER_ParseServerStatus( $$ ) {
    my( $hash, $dataptr ) = @_;
   
    my $name = $hash->{NAME};

    Log3( $hash, 4, "SB_SERVER_ParseServerStatus($name): called " );
    
    # typically the start index being a number
    if( $dataptr->[ 0 ] =~ /^([0-9])*/ ) {
	shift( @{$dataptr} );
    } else {
	Log3( $hash, 5, "SB_SERVER_ParseServerStatus($name): entry is " .
	      "not the start number" );
	return;
    }

    # typically the max index being a number
    if( $dataptr->[ 0 ] =~ /^([0-9])*/ ) {
	shift( @{$dataptr} );
    } else {
	Log3( $hash, 5, "SB_SERVER_ParseServerStatus($name): entry is " .
	      "not the end number" );
	return;
    }

    my $datastr = join( " ", @{$dataptr} );
    # replace funny stuff
    $datastr =~ s/info total albums/infototalalbums/g;
    $datastr =~ s/info total artists/infototalartists/g;
    $datastr =~ s/info total songs/infototalsongs/g;
    $datastr =~ s/info total genres/infototalgenres/g;
    $datastr =~ s/sn player count/snplayercount/g;
    $datastr =~ s/other player count/otherplayercount/g;
    $datastr =~ s/player count/playercount/g;

    Log3( $hash, 5, "SB_SERVER_ParseServerStatus($name): data to parse: " .
	  $datastr );

    my @data1 = split( " ", $datastr );

    # the rest of the array should now have the data, we're interested in
    readingsBeginUpdate( $hash );

    # set default values for stuff not always send
    readingsBulkUpdate( $hash, "scanning", "no" );
    readingsBulkUpdate( $hash, "scandb", "?" );
    readingsBulkUpdate( $hash, "scanprogressdone", "0" );
    readingsBulkUpdate( $hash, "scanprogresstotal", "0" );
    readingsBulkUpdate( $hash, "scanlastfailed", "none" );

    my $addplayers = true;
    my %players;
    my $currentplayerid = "none";

    # needed for scanning the MAC Adress
    my $d = "[0-9A-Fa-f]";
    my $dd = "$d$d";

    # needed for scanning the IP adress
    my $e = "[0-9]";
    my $ee = "$e$e";

    foreach( @data1 ) {
	if( $_ =~ /^(lastscan:)([0-9]*)/ ) {
	    # we found the lastscan entry
	    my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = 
		localtime( $2 );
	    $year = $year + 1900;
	    readingsBulkUpdate( $hash, "scan_last", "$mday-".($mon+1)."-$year " .   # CD 0016 Monat korrigiert
				"$hour:$min:$sec" );
	    next;
	} elsif( $_ =~ /^(scanning:)([0-9]*)/ ) {
	    readingsBulkUpdate( $hash, "scanning", $2 );
	    next;
	} elsif( $_ =~ /^(rescan:)([0-9]*)/ ) {
	    if( $2 eq "1" ) {
		readingsBulkUpdate( $hash, "scanning", "yes" );
	    } else {
		readingsBulkUpdate( $hash, "scanning", "no" );
	    }
	    next;
	} elsif( $_ =~ /^(version:)([0-9\.]*)/ ) {
	    readingsBulkUpdate( $hash, "serverversion", $2 );
	    next;
	} elsif( $_ =~ /^(playercount:)([0-9]*)/ ) {
	    readingsBulkUpdate( $hash, "players", $2 );
	    next;
	} elsif( $_ =~ /^(snplayercount:)([0-9]*)/ ) {
	    readingsBulkUpdate( $hash, "players_mysb", $2 );
	    $currentplayerid = "none";
	    $addplayers = false;
	    next;
	} elsif( $_ =~ /^(otherplayercount:)([0-9]*)/ ) {
	    readingsBulkUpdate( $hash, "players_other", $2 );
	    $currentplayerid = "none";
	    $addplayers = false;
	    next;
	} elsif( $_ =~ /^(infototalalbums:)([0-9]*)/ ) {
	    readingsBulkUpdate( $hash, "db_albums", $2 );
	    next;
	} elsif( $_ =~ /^(infototalartists:)([0-9]*)/ ) {
	    readingsBulkUpdate( $hash, "db_artists", $2 );
	    next;
	} elsif( $_ =~ /^(infototalsongs:)([0-9]*)/ ) {
	    readingsBulkUpdate( $hash, "db_songs", $2 );
	    next;
	} elsif( $_ =~ /^(infototalgenres:)([0-9]*)/ ) {
	    readingsBulkUpdate( $hash, "db_genres", $2 );
	    next;
	} elsif( $_ =~ /^(playerid:)($dd[:|-]$dd[:|-]$dd[:|-]$dd[:|-]$dd[:|-]$dd)/ ) {
	    my $id = join( "", split( ":", $2 ) );
	    if( $addplayers == true ) { # CD 0017 fixed ==
		$players{$id}{ID} = $id;
		$players{$id}{MAC} = $2;
		$currentplayerid = $id;
	    }
	    next;
	} elsif( $_ =~ /^(name:)(.*)/ ) {
	    if( $currentplayerid ne "none" ) {
		$players{$currentplayerid}{name} = $2;
	    }
	    next;
	} elsif( $_ =~ /^(displaytype:)(.*)/ ) {
	    if( $currentplayerid ne "none" ) {
		$players{$currentplayerid}{displaytype} = $2;
	    }
	    next;
	} elsif( $_ =~ /^(model:)(.*)/ ) {
	    if( $currentplayerid ne "none" ) {
		$players{$currentplayerid}{model} = $2;
	    }
	    next;
	} elsif( $_ =~ /^(power:)([0|1])/ ) {
	    if( $currentplayerid ne "none" ) {
		$players{$currentplayerid}{power} = $2;
	    }
	    next;
	} elsif( $_ =~ /^(canpoweroff:)([0|1])/ ) {
	    if( $currentplayerid ne "none" ) {
		$players{$currentplayerid}{canpoweroff} = $2;
	    }
	    next;
	} elsif( $_ =~ /^(connected:)([0|1])/ ) {
	    if( $currentplayerid ne "none" ) {
		$players{$currentplayerid}{connected} = $2;
	    }
	    next;
	} elsif( $_ =~ /^(isplayer:)([0|1])/ ) {
	    if( $currentplayerid ne "none" ) {
		$players{$currentplayerid}{isplayer} = $2;
	    }
	    next;
	} elsif( $_ =~ /^(ip:)(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}:\d{3,5})/ ) {
	    if( $currentplayerid ne "none" ) {
		$players{$currentplayerid}{IP} = $2;
	    }
	    next;
	} elsif( $_ =~ /^(seq_no:)(.*)/ ) {
	    # just to take care of the keyword
	    next;
    # CD 0017 start
	} elsif( $_ =~ /^(isplaying:)(.*)/ ) {
	    # just to take care of the keyword
	    next;
	} elsif( $_ =~ /^(snplayercount:)(.*)/ ) {
	    # just to take care of the keyword
	    next;
	} elsif( $_ =~ /^(otherplayercount:)(.*)/ ) {
	    # just to take care of the keyword
	    next;
	} elsif( $_ =~ /^(server:)(.*)/ ) {
	    # just to take care of the keyword
	    next;
	} elsif( $_ =~ /^(serverurl:)(.*)/ ) {
	    # just to take care of the keyword
	    next;
    # CD 0017 end
	} else {
	    # no keyword found, so let us assume it is part of the player name
	    if( $currentplayerid ne "none" ) {
		$players{$currentplayerid}{name} .= $_;
	    }

	}
    }

    readingsEndUpdate( $hash, 1 );

    my @ignoredIPs=split(',',AttrVal($name,'ignoredIPs',''));   # CD 0017
    my @ignoredMACs=split(',',AttrVal($name,'ignoredMACs',''));   # CD 0017
    
    foreach my $player ( keys %players ) {
	if( defined( $players{$player}{isplayer} ) ) {
	    if( $players{$player}{isplayer} eq "0" ) {
		Log3( $hash, 1, "not a player" );
		next;
	    }
	}

    # CD 0017 check ignored IPs
	if( defined( $players{$player}{IP} ) ) {
        my @ip=split(':',$players{$player}{IP});
        if ($ip[0] ~~ @ignoredIPs) {
            $players{$player}{ignore}=1;
            next;
        }
    }
    
    # CD 0017 check ignored MACs
	if( defined( $players{$player}{MAC} ) ) {
        if ($players{$player}{MAC} ~~ @ignoredMACs) {
            $players{$player}{ignore}=1;
            next;
        }
    }

	# if the player is not yet known, it will be created
	if( defined( $players{$player}{ID} ) ) {
	    Dispatch( $hash, "SB_PLAYER:$players{$player}{ID}:NONE", undef );
	} else {
	    Log3( $hash, 1, "not defined" );
	    next;
	}

	if( defined( $players{$player}{name} ) ) {
	    Dispatch( $hash, "SB_PLAYER:$players{$player}{ID}:" . 
		      "name $players{$player}{name}", undef );
	}

	if( defined( $players{$player}{IP} ) ) {
	    Dispatch( $hash, "SB_PLAYER:$players{$player}{ID}:" . 
		      "player ip $players{$player}{IP}", undef );
	}

	if( defined( $players{$player}{model} ) ) {
	    Dispatch( $hash, "SB_PLAYER:$players{$player}{ID}:" . 
		      "player model $players{$player}{model}", undef );
	}

	if( defined( $players{$player}{canpoweroff} ) ) {
	    Dispatch( $hash, "SB_PLAYER:$players{$player}{ID}:" . 
		      "player canpoweroff $players{$player}{canpoweroff}", 
		      undef );
	}

	if( defined( $players{$player}{power} ) ) {
	    Dispatch( $hash, "SB_PLAYER:$players{$player}{ID}:" . 
		      "power $players{$player}{power}", undef );
	}

	if( defined( $players{$player}{connected} ) ) {
	    Dispatch( $hash, "SB_PLAYER:$players{$player}{ID}:" . 
		      "connected $players{$player}{connected}", undef );
	}

	if( defined( $players{$player}{displaytype} ) ) {
	    Dispatch( $hash, "SB_PLAYER:$players{$player}{ID}:" . 
		      "displaytype $players{$player}{displaytype}", undef );
	}
    }

    # the list for the sync masters
    # make all client create e new sync master list
    SB_SERVER_Broadcast( $hash, "SYNCMASTER",  
			 "FLUSH dont care", undef );

    # now send the list for the sync masters
    foreach my $player ( keys %players ) {
        next if defined($players{$player}{ignore});
        my $uniqueid = join( "", split( ":", $players{$player}{MAC} ) );
        Log3( $hash, 1, "SB_SERVER_ParseServerStatus($name): player has no name") unless defined($players{$player}{name});
        Log3( $hash, 1, "SB_SERVER_ParseServerStatus($name): player has no MAC") unless defined($players{$player}{MAC});
        SB_SERVER_Broadcast( $hash, "SYNCMASTER",  
                     "ADD $players{$player}{name} " . 
                     "$players{$player}{MAC} $uniqueid", undef );
    }


    return;
}


# ----------------------------------------------------------------------------
#  Parse the return values of the favorites items
# ----------------------------------------------------------------------------
sub SB_SERVER_FavoritesParse( $$ ) {
    my ( $hash, $str ) = @_;
    
    my $name = $hash->{NAME};

    Log3( $hash, 5, "SB_SERVER_FavoritesParse($name): called" );

    # flush the existing list
    foreach my $titi ( keys %{$favorites{$name}} ) {
	delete( $favorites{$name}{$titi} );
    }

    # split up the string we got
    my @data = split( " ", $str );

    # eliminate the first entries of the response
    # some more comment
    # typically 'items'
    if( $data[ 0 ] =~ /^(items)*/ ) {
	my $notneeded = shift( @data );
    } 
    
    # typically the start index being a number
    if( $data[ 0 ] =~ /^([0-9])*/ ) {
	my $notneeded = shift( @data );
    }

    # typically the start index being a number
    my $maxwanted = 100;
    if( $data[ 0 ] =~ /^([0-9])*/ ) {
	$maxwanted = int( shift( @data ) );
    }

    # find the maximum number of favorites. That is typically at the 
    # end of the server response. So check there first
    my $totals = 0;
    my $lastdata = $data[ $#data ];
    if( $lastdata =~ /^(count:)([0-9]*)/ ) {
	$totals = $2;
	# remove the last element from the array
	pop( @data );
    } else {
	my $i = 0;
	my $delneeded = false;
	foreach( @data ) {
	    if( $_ =~ /^(count:)([0-9]*)/ ) {
		$totals = $2;
		$delneeded = true;
		last;
	    } else {
		$i++;
	    }
	    
	    # delete the element from the list
	    if( $delneeded == true ) {
		splice( @data, $i, 1 );
	    }
	}
    }
    readingsSingleUpdate( $hash, "favoritestotal", $totals, 0 );


    my $favname = "";
    if( $data[ 0 ] =~ /^(title:)(.*)/ ) {
	$favname = $2;
	shift( @data );
    }
    readingsSingleUpdate( $hash, "favoritesname", $favname, 0 );

    # check if we got all the favoites with our response
    if( $totals > $maxwanted ) {
	# we asked for too less data, there are more favorites defined
    }

    # treat the rest of the string
    my $namestarted = false;
    my $firstone = true;

    my $namebuf = "";
    my $idbuf = "";
    my $hasitemsbuf = false;
    my $isaudiobuf = "";
    my $isplaylist = false;
    my $url = "?";           # CD 0009 hinzugef�gt

    foreach ( @data ) {
    #Log 0,$_;
	if( $_ =~ /^(id:|ID:)([A-Za-z0-9\.]*)/ ) {
	    # we found an ID, that is typically the start of a new session
	    # so save the old session first
	    if( $firstone == false ) {
            if(( $hasitemsbuf == false )||($isplaylist == true)) {
                # derive our hash entry
                my $entryuid = SB_SERVER_FavoritesName2UID( $namebuf );     # CD 0009 decode hinzugef�gt # CD 0010 decode wieder entfernt
                $favorites{$name}{$entryuid} = {
                ID => $idbuf,
                Name => $namebuf,
                URL => $url, };         # CD 0009 hinzugef�gt
                $namebuf = "";
                $isaudiobuf = "";
                $url = "?";              # CD 0009 hinzugef�gt
                $hasitemsbuf = false;
                $isplaylist = false;
            } else {
                # that is a folder we found, but we don't handle that
            }	   
	    }

	    $firstone = false;
	    $idbuf = $2;

	    # if there has been a name found before, end it now
	    if( $namestarted == true ) {
		$namestarted = false;
	    }

	} elsif( $_ =~ /^(isaudio:)([0|1]?)/ ) {
	    $isaudiobuf = $2;
	    if( $namestarted == true ) {
		$namestarted = false;
	    }

	} elsif( $_ =~ /^(hasitems:)([0|1]?)/ ) {
	    if( int( $2 ) == 0 ) { 
		$hasitemsbuf = false;
	    } else {
		$hasitemsbuf = true;
	    }

	    if( $namestarted == true ) {
		$namestarted = false;
	    }
    # CD 0018 start
    } elsif( $_ =~ /^(type:)(.*)/ ) {
        $isplaylist = true if($2 eq "playlist");
	    if( $namestarted == true ) {
            $namestarted = false;
	    }
    # CD 0018 end
	#} elsif( $_ =~ /^(name:)([0-9a-zA-Z]*)/ ) {     # CD 0007   # CD 0009 deaktiviert
	} elsif( $_ =~ /^(name:)(.*)/ ) {     # CD 0009 hinzugef�gt
	    $namebuf = $2;
	    $namestarted = true;
    
    # CD 0009 start
	} elsif( $_ =~ /^(url:)(.*)/ ) {
	    $url = $2;
        $url =~ s/file:\/\/\///;
    # CD 0009 end
    } else {
	    # no regexp matched, so it must be part of the name
	    if( $namestarted == true ) {
		$namebuf .= " " . $_;
	    }
	}
    }

    # capture the last element also
    if( ( $namebuf ne "" ) && ( $idbuf ne "" ) ) {
    if(( $hasitemsbuf == false )||($isplaylist == true)) {
	    # CD 0003 replaced ** my $entryuid = join( "", split( " ", $namebuf ) ); ** with:
        my $entryuid = SB_SERVER_FavoritesName2UID( $namebuf );             # CD 0009 decode hinzugef�gt # CD 0010 decode wieder entfernt
	    $favorites{$name}{$entryuid} = {
		ID => $idbuf,
		Name => $namebuf,
        URL => $url, };         # CD 0009 hinzugef�gt
	} else {
	    # that is a folder we found, but we don't handle that
	}
    }

    # make all client create e new favorites list
    SB_SERVER_Broadcast( $hash, "FAVORITES",  
			 "FLUSH dont care", undef );

    # find all the names and broadcast to our clients
    $favsetstring = "favorites:";
    foreach my $titi ( keys %{$favorites{$name}} ) {
	Log3( $hash, 5, "SB_SERVER_ParseFavorites($name): " . 
	      "ID:" .  $favorites{$name}{$titi}{ID} . 
	      " Name:" . $favorites{$name}{$titi}{Name} . " $titi" );
	$favsetstring .= "$titi,";
	SB_SERVER_Broadcast( $hash, "FAVORITES",  
			     "ADD $name $favorites{$name}{$titi}{ID} " . 
			     "$titi $favorites{$name}{$titi}{URL} $favorites{$name}{$titi}{Name}", undef );     # CD 0009 URL an Player schicken
    }
    #chop( $favsetstring );
    #$favsetstring .= " ";
}


# ----------------------------------------------------------------------------
#  generate a UID for the hash entry from the name
# ----------------------------------------------------------------------------
sub SB_SERVER_FavoritesName2UID( $ ) {
    my $namestr = shift( @_ );

    # eliminate spaces
    $namestr = join( "_", split( " ", $namestr ) );     # CD 0009 Leerzeichen durch _ ersetzen statt l�schen

    # CD 0009 verschiedene Sonderzeichen ersetzen und nicht mehr l�schen
    my %Sonderzeichen = ("�" => "ae", "�" => "Ae", "�" => "ue", "�" => "Ue", "�" => "oe", "�" => "Oe", "�" => "ss",
                        "�" => "e", "�" => "e", "�" => "e", "�" => "a", "�" => "c" );
    my $Sonderzeichenkeys = join ("|", keys(%Sonderzeichen));
    $namestr =~ s/($Sonderzeichenkeys)/$Sonderzeichen{$1}/g;
    # CD 0009

    # this defines the regexp. Please add new stuff with the seperator |
    # CD 0003 changed �� to �|�
    my $tobereplaced = '[�|�|�|�|�|�|\[|\]|\{|\}|\(|\)|\\\\|,|:|\?|' .       # CD 0011 ,:? hinzugef�gt
	'\/|\'|\.|\"|\^|�|\$|\||%|@|&|\+]';     # CD 0009 + hinzugef�gt

    $namestr =~ s/$tobereplaced//g;

    return( $namestr );
}

# ----------------------------------------------------------------------------
#  push a command to the buffer
# ----------------------------------------------------------------------------
sub SB_SERVER_CMDStackPush( $$ ) {
    my ( $hash, $cmd ) = @_;

    my $name = $hash->{NAME};

    my $n = $SB_SERVER_CmdStack{$name}{last_n};
    
    $n=0 if(!defined($n));                                          # CD 0007

    if( $n > AttrVal( $name, "maxcmdstack", 200 ) ) {
        Log3( $hash, 5, "SB_SERVER_CMDStackPush($name): limit reached" );
        SB_SERVER_CMDStackPop($hash);                               # CD 0007 added
        #return;                                                    # CD 0007 disabled
    }

    $SB_SERVER_CmdStack{$name}{$n}{CMD} = $cmd;
    $SB_SERVER_CmdStack{$name}{$n}{TS} = time();                    # CD 0007

    $n = $n + 1;

    $SB_SERVER_CmdStack{$name}{last_n} = $n;
    $SB_SERVER_CmdStack{$name}{first_n} = $n if (!defined($SB_SERVER_CmdStack{$name}{first_n}));    # CD 0007
    
    # update overall number of entries
    $SB_SERVER_CmdStack{$name}{cnt} = $SB_SERVER_CmdStack{$name}{last_n} - 
	$SB_SERVER_CmdStack{$name}{first_n} + 1;
    $hash->{CMDSTACK}=$SB_SERVER_CmdStack{$name}{cnt};              # CD 0007
}

# ----------------------------------------------------------------------------
#  pop a command from the buffer
# ----------------------------------------------------------------------------
sub SB_SERVER_CMDStackPop( $ ) {
    my ( $hash ) = @_;
    
    my $name = $hash->{NAME};
    
    my $n = $SB_SERVER_CmdStack{$name}{first_n};

    $n=0 if(!defined($n));                                          # CD 0007
    
    my $res = "";
    # return the first element of the list
    if( defined( $SB_SERVER_CmdStack{$name}{$n} ) ) {
        $res = $SB_SERVER_CmdStack{$name}{$n}{CMD};
        $res = "empty" if($SB_SERVER_CmdStack{$name}{$n}{TS}<time()-300);               # CD 0007 drop commands older than 5 minutes
    } else {
        $res = "empty";
    }

    # and now remove the first element
    
    delete( $SB_SERVER_CmdStack{$name}{$n} );
    
    $n = $n + 1;
    
    if ( $n <= $SB_SERVER_CmdStack{$name}{last_n} ) {                                   # CD 0000 changed first_n to last_n
	$SB_SERVER_CmdStack{$name}{first_n} = $n;
	# update overall number of entries
	$SB_SERVER_CmdStack{$name}{cnt} = $SB_SERVER_CmdStack{$name}{last_n} - 
	    $SB_SERVER_CmdStack{$name}{first_n} + 1;
    } else {
	# end of list reached
	$SB_SERVER_CmdStack{$name}{last_n} = 0;
	$SB_SERVER_CmdStack{$name}{first_n} = 0;
	$SB_SERVER_CmdStack{$name}{cnt} = 0;
    }
    $hash->{CMDSTACK}=$SB_SERVER_CmdStack{$name}{cnt};          # CD 0007
    
    return( $res );
}


# CD 0011 start
# ----------------------------------------------------------------------------
#  parse the list of known alarm playlists
# ----------------------------------------------------------------------------
sub SB_SERVER_ParseServerAlarmPlaylists( $$ ) {
    my( $hash, $dataptr ) = @_;
    
    my $name = $hash->{NAME};

    Log3( $hash, 4, "SB_SERVER_ParseServerAlarmPlaylists($name): called" );

    # force all clients to delete alarm playlists
    SB_SERVER_Broadcast( $hash, "ALARMPLAYLISTS",  
			 "FLUSH dont care", undef );

    my @r=split("category:",join(" ",@{$dataptr}));
    foreach my $a (@r){
        my $i1=index($a," title:");
        my $i2=index($a," url:");
        my $i3=index($a," singleton:");
        if (($i1!=-1)&&($i2!=-1)&&($i3!=-1)) {
            my $url=substr($a,$i2+5,$i3-$i2-5);
            $url=substr($a,$i1+7,$i2-$i1-7) if ($url eq "");
            my $pn=SB_SERVER_FavoritesName2UID(decode('utf-8',$url));
            SB_SERVER_Broadcast( $hash, "ALARMPLAYLISTS",  
                        "ADD $pn category ".substr($a,0,$i1), undef );
            SB_SERVER_Broadcast( $hash, "ALARMPLAYLISTS",  
                        "ADD $pn title ".substr($a,$i1+7,$i2-$i1-7), undef );
            SB_SERVER_Broadcast( $hash, "ALARMPLAYLISTS",  
                        "ADD $pn url $url", undef );
        }
    }
}
# CD 0011 end

# ----------------------------------------------------------------------------
#  parse the list of known Playlists
# ----------------------------------------------------------------------------
sub SB_SERVER_ParseServerPlaylists( $$ ) {
    my( $hash, $dataptr ) = @_;
    
    my $name = $hash->{NAME};

    Log3( $hash, 4, "SB_SERVER_ParseServerPlaylists($name): called" );

    my $namebuf = "";
    my $uniquename = "";
    my $idbuf = -1;
    
    # typically the start index being a number
    if( $dataptr->[ 0 ] =~ /^([0-9])*/ ) {
	shift( @{$dataptr} );
    } else {
	Log3( $hash, 5, "SB_SERVER_ParseServerPlaylists($name): entry is " .
	      "not the start number" );
	return;
    }

    # typically the max index being a number
    if( $dataptr->[ 0 ] =~ /^([0-9])*/ ) {
	shift( @{$dataptr} );
    } else {
	Log3( $hash, 5, "SB_SERVER_ParseServerPlaylists($name): entry is " .
	      "not the end number" );
	return;
    }

    my $datastr = join( " ", @{$dataptr} );

    Log3( $hash, 5, "SB_SERVER_ParseServerPlaylists($name): data to parse: " .
	  $datastr );

    # make all client create a new favorites list
    SB_SERVER_Broadcast( $hash, "PLAYLISTS",  
			 "FLUSH dont care", undef );

    my @data1 = split( " ", $datastr );

    foreach( @data1 ) {
	if( $_ =~ /^(id:)(.*)/ ) {
	    Log3( $hash, 5, "SB_SERVER_ParseServerPlaylists($name): " . 
		  "id:$idbuf name:$namebuf " );
	    if( $idbuf != -1 ) {
		$uniquename = SB_SERVER_FavoritesName2UID( $namebuf );          # CD 0009 decode hinzugef�gt # CD 0010 decode wieder entfernt
		SB_SERVER_Broadcast( $hash, "PLAYLISTS",  
				     "ADD $namebuf $idbuf $uniquename", undef );
	    }
	    $idbuf = $2;
	    $namebuf = "";
	    $uniquename = "";
	    next;
	} elsif( $_ =~ /^(playlist:)(.*)/ ) {
	    $namebuf = $2;
	    next;
	} elsif( $_ =~ /^(count:)([0-9]*)/ ) {
	    # the last entry of the return
	    Log3( $hash, 5, "SB_SERVER_ParseServerPlaylists($name): " . 
		  "id:$idbuf name:$namebuf " );
	    if( $idbuf != -1 ) {
		$uniquename = SB_SERVER_FavoritesName2UID( $namebuf );          # CD 0009 decode hinzugef�gt # CD 0010 decode wieder entfernt
		SB_SERVER_Broadcast( $hash, "PLAYLISTS",  
				     "ADD $namebuf $idbuf $uniquename", undef );
	    }
	    
	} else {
	    $namebuf .= "_" . $_;
	    next;
	}
    }

    return;
}

# CD 0008 start
sub SB_SERVER_CheckConnection($) {
    my($in ) = shift;
    my(undef,$name) = split(':',$in);
    my $hash = $defs{$name};

    Log3( $hash, 3, "SB_SERVER_CheckConnection($name): STATE: " . $hash->{STATE} . " power: ". ReadingsVal( $name, "power", "X" )); # CD 0009 level 2->3
    if(ReadingsVal( $name, "power", "X" ) ne "on") {
        Log3( $hash, 3, "SB_SERVER_CheckConnection($name): forcing power on");      # CD 0009 level 2->3
        
        $hash->{helper}{pingCounter}=0;
            
        SB_SERVER_Broadcast( $hash, "SERVER", 
                 "IP " . $hash->{IP} . ":" .
                 AttrVal( $name, "httpport", "9000" ) );
        $hash->{helper}{doBroadcast}=1;

        SB_SERVER_LMS_Status( $hash );
        if( AttrVal( $name, "doalivecheck", "false" ) eq "false" ) {
            readingsSingleUpdate( $hash, "power", "on", 1 );
        } elsif( AttrVal( $name, "doalivecheck", "false" ) eq "true" ) {
            # start the alive checking mechanism
            # CD 0020 SB_SERVER_tcb_Alive verwenden
            RemoveInternalTimer( "SB_SERVER_Alive:$name");
            InternalTimer( gettimeofday() + 
                       AttrVal( $name, "alivetimer", 10 ),
                       "SB_SERVER_tcb_Alive",
                       "SB_SERVER_Alive:$name", 
                       0 );
        }
    }
    RemoveInternalTimer( "CheckConnection:$name");
}    
# CD 0008 end

# ----------------------------------------------------------------------------
#  the Notify function
# ----------------------------------------------------------------------------
sub SB_SERVER_Notify( $$ ) {
    my ( $hash, $dev_hash ) = @_;
    my $name = $hash->{NAME}; # own name / hash
    my $devName = $dev_hash->{NAME}; # Device that created the events

    # CD start
    if ($dev_hash->{NAME} eq "global" && grep (m/^INITIALIZED$|^REREADCFG$/,@{$dev_hash->{CHANGED}})){
    DevIo_OpenDev($hash, 0, "SB_SERVER_DoInit" );
    }
    # CD end
    #Log3( $hash, 4, "SB_SERVER_Notify($name): called" . 
    #    "Own:" . $name . " Device:" . $devName );

    # CD 0008 start
    if($devName eq $name ) {
        if (grep (m/^DISCONNECTED$/,@{$dev_hash->{CHANGED}})) {
            Log3( $hash, 3, "SB_SERVER_Notify($name): DISCONNECTED - STATE: " . $hash->{STATE} . " power: ". ReadingsVal( $name, "power", "X" ));   # CD 0009 level 2->3
            RemoveInternalTimer( "CheckConnection:$name");
        }
        if (grep (m/^CONNECTED$/,@{$dev_hash->{CHANGED}})) {
            Log3( $hash, 3, "SB_SERVER_Notify($name): CONNECTED - STATE: " . $hash->{STATE} . " power: ". ReadingsVal( $name, "power", "X" ));      # CD 0009 level 2->3
            InternalTimer( gettimeofday() + 2, 
                "SB_SERVER_CheckConnection", 
                "CheckConnection:$name",
                 0 );
        }
    }
    # CD 0008 end

    if( $devName eq $hash->{RCCNAME} ) {
        if( ReadingsVal( $hash->{RCCNAME}, "state", "off" ) eq "off" ) {
            RemoveInternalTimer( $hash );
            # CD 0020 SB_SERVER_tcb_Alive verwenden
            RemoveInternalTimer( "SB_SERVER_Alive:$name");
            InternalTimer( gettimeofday() + 10, 
                       "SB_SERVER_tcb_Alive",
                       "SB_SERVER_Alive:$name", 
                       0 );

            # CD 0007 use DevIo_Disconnected instead of DevIo_CloseDev
            #DevIo_CloseDev( $hash ); 
            DevIo_Disconnected( $hash ); 
            $hash->{helper}{pingCounter}=9999;                                  # CD 0007
            $hash->{CLICONNECTION} = "off";                                     # CD 0007
            # CD 0005 set state after DevIo_CloseDev
            # CD 0006 DevIo_setStates requires v7099 of DevIo.pm, replaced with SB_SERVER_setStates
            SB_SERVER_setStates($hash, "disconnected");
        } elsif( ReadingsVal( $hash->{RCCNAME}, "state", "off" ) eq "on" ) {
            RemoveInternalTimer( $hash );
            # do an update of the status, but SB CLI must come up
            # CD 0020 SB_SERVER_tcb_Alive verwenden
            RemoveInternalTimer( "SB_SERVER_Alive:$name");
            InternalTimer( gettimeofday() + 20, 
                       "SB_SERVER_tcb_Alive",
                       "SB_SERVER_Alive:$name", 
                       0 );
        } else {
            return( undef );
        }
        return( "" );
    # CD 0007 start
    } elsif( $devName eq $hash->{PRESENCENAME} ) {
        if(grep (m/^present$|^absent$/,@{$dev_hash->{CHANGED}})) {
            Log3( $hash, 3, "SB_SERVER_Notify($name): $devName changed to ". join(" ",@{$dev_hash->{CHANGED}}));    # CD 0023 loglevel 2->3
            # CD 0023 start
            if (defined($hash->{helper}{lastPRESENCEstate})) {
                if($hash->{helper}{lastPRESENCEstate} eq $dev_hash->{CHANGED}[0]) {
                    # nichts ge�ndert
                    return( undef );
                }
            }
            $hash->{helper}{lastPRESENCEstate}=$dev_hash->{CHANGED}[0];
            # CD 0023 end
            RemoveInternalTimer( $hash );
            # do an update of the status, but SB CLI must come up
            # CD 0020 SB_SERVER_tcb_Alive verwenden
            RemoveInternalTimer( "SB_SERVER_Alive:$name");
            InternalTimer( gettimeofday() + 10, 
                       "SB_SERVER_tcb_Alive",
                       "SB_SERVER_Alive:$name", 
                       0 );
            return( "" );
        } else {
            return( undef );
        }
    # CD 0007 end
    } else {
        return( undef );
    }
}

# ----------------------------------------------------------------------------
#  start up the LMS server status
# ----------------------------------------------------------------------------
sub SB_SERVER_LMS_Status( $ ) {
    my ( $hash ) = @_;
    my $name = $hash->{NAME}; # own name / hash

    # CD 0007 login muss als erstes gesendet werden
    $hash->{helper}{SB_SERVER_LMS_Status}=time();
    if( ( $hash->{USERNAME} ne "?" ) && 
        ( $hash->{PASSWORD} ne "?" ) ) {
        DevIo_SimpleWrite( $hash, "login " . 
                   $hash->{USERNAME} . " " . 
                   $hash->{PASSWORD} . "\n", 
                   0 );
    }
    
    # subscribe us
    DevIo_SimpleWrite( $hash, "listen 1\n", 0 );

    # and get some info on the server
    DevIo_SimpleWrite( $hash, "pref authorize ?\n", 0 );
    DevIo_SimpleWrite( $hash, "version ?\n", 0 );
    DevIo_SimpleWrite( $hash, "serverstatus 0 200\n", 0 );
    DevIo_SimpleWrite( $hash, "favorites items 0 " . 
		       AttrVal( $name, "maxfavorites", 100 ) . " want_url:1\n", 0 );   # CD 0009 url mit abfragen
    DevIo_SimpleWrite( $hash, "playlists 0 200\n", 0 );
    DevIo_SimpleWrite( $hash, "alarm playlists 0 300\n", 0 );       # CD 0011

    return( true );
}

# CD 0006 start - added
# ----------------------------------------------------------------------------
#  copied from DevIo.pm 7099
# ----------------------------------------------------------------------------
sub SB_SERVER_setStates($$)
{
  my ($hash, $val) = @_;
  $hash->{STATE} = $val;
  setReadingsVal($hash, "state", $val, TimeNow());
}
# CD 0006 end


# ############################################################################
#  No PERL code beyond this line
# ############################################################################
1;

=pod
=item device 
=item summary    connect to a Logitech Media Server (LMS)
=item summary_DE Anbindung an Logitech Media Server (LMS) 
=begin html

<a name="SB_SERVER"></a>
<h3>SB_SERVER</h3>
<ul>
  <a name="SBserverdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; SB_SERVER &lt;ip[:cliserverport]&gt; [RCC:&lt;RCC&gt;] [WOL:&lt;WOL&gt;] [PRESENCE:&lt;PRESENCE&gt;] [USER:&lt;username&gt;] [PASSWORD:&lt;password&gt;]</code>
    <br><br>

    This module allows you in combination with the module SB_PLAYER to control a
    Logitech Media Server (LMS) and connected Squeezebox Media Players.<br><br>
   
    Attention:  The <code>[:cliserverport]</code> parameter is
    optional. You just need to configure it if you changed it on the LMS.
    The default TCP port is 9090.<br><br>   
    <b>Optional</b>
    <ul>
      <li><code>&lt;[RCC]&gt;</code>: You can define a FHEM RCC Device, if you want to wake it up when you set the SB_SERVER on.  </li>
      <li><code>&lt;[WOL]&gt;</code>: You can define a FHEM WOL Device, if you want to wake it up when you set the SB_SERVER on.  </li>
      <li><code>&lt;[PRESENCE]&gt;</code>: You can define a FHEM PRESENCE Device that is used to check if the server is reachable.  </li>
      <li><code>&lt;username&gt;</code> and <code>&lt;password&gt;</code>: If your LMS is password protected you can define the credentials here.  </li>
    </ul><br>
  </ul>
  <a name="SBserverset"></a>
  <b>Set</b>
  <ul>
    <code>set &lt;name&gt; &lt;command&gt;</code>
    <br><br>
    This module supports the following SB_Server related commands:<br><br>
    <ul>
      <li><b>abort</b> -  Stops the connection to the server</li>
      <li><b>addToFHEMUpdate</b> -  Includes the modules in the FHEM update, needs to be executed only once</li>
      <li><b>cliraw &lt;cli-command&gt;</b> -  Sends a &lt;cli-command&gt; to the LMS CLI</li>
      <li><b>on</b> -  Tries to switch on the Server by WOL or RCC</li>
      <li><b>removeFromFHEMUpdate</b> -  Removes the modules from the FHEM update</li>
      <li><b>renew</b> -  Renews the connection to the server</li>
      <li><b>rescan</b> -  Starts the scan of the music library of the server</li>
      <li><b>statusRequest</b> -  Update of readings from server and configured players</li>
    </ul>   
    <br>
  </ul>
  <a name="SBserverattr"></a>
  <b>Attributes</b>
  <ul>
    <li><code>alivetimer &lt;sec&gt;</code><br>
    Default: 120. Every &lt;sec&gt; seconds it is checked, whether the computer with its LMS is still reachable
    � either via an internal ping (that leads regulary to problems) or via PRESENCE (preferred, no problems)
    - and running.</li>
    <li><code>doalivecheck &lt;true|false&gt;</code><br>
    Switches the LMS-monitoring on or off.</li>
    <li><code>httpport &lt;port&gt;</code><br>
    Normally the http-port is set to 9000. If this ist NOT the case, you have to enter here the new
    port-number. You can check the port-number of the LMS within its setup under Setup � Network � Web Server Port Number.</li>
    <li><a name="SBserver_attribut_ignoredIPs"><code>ignoredIPs &lt;IP-Address[,IP-Address]&gt;</code>
    </a><br />With this attribute you can define IP-addresses of players which will to be ignored by the server, e.g. "192.168.0.11,192.168.0.37"</li>
    <li><a name="SBserver_attribut_ignoredMACs"><code>ignoredMACs &lt;MAC-Address[,MAC-Address]&gt;</code>
    </a><br />With this attribute you can define MAC-addresses of players which will to be ignored by the server, e.g. "00:11:22:33:44:55,ff:ee:dd:cc:bb:aa"</li>
    <li><code>maxcmdstack &lt;quantity&gt;</code><br>
    By default the stack ist set up to 200. If the connection to the LMS is lost, up to &lt;quantity&gt;
    commands are buffered. After the link is reconnected, commands, that are not older than five minutes,
    are send to the LMS.</li>
    <li><code>maxfavorites &lt;number&gt;</code><br>
    Adjust here the maximal number of the favourites.</li>
  </ul>
</ul>
=end html

=begin html_DE

<a name="SB_SERVER"></a>
<h3>SB_SERVER</h3>
<ul>
  <a name="SBserverdefine"></a>
  <b>Define</b>
  <ul>
    <code>define &lt;name&gt; SB_SERVER &lt;ip[:cliserverport]&gt; [RCC:&lt;RCC&gt;] [WOL:&lt;WOL&gt;] [PRESENCE:&lt;PRESENCE&gt;] [USER:&lt;username&gt;] [PASSWORD:&lt;password&gt;]</code>
    <br><br>

    Diese Modul erm&ouml;glicht es - zusammen mit dem Modul SB_PLAYER - einen
    Logitech Media Server (LMS) und die angeschlossenen Squeezebox Media
    Player zu steuern.<br><br>
   
    Achtung: Die Angabe des Parameters <code>[:cliserverport]</code> ist
    optional und nur dann erforderlich, wenn die Portnummer im LMS vom
    Standardwert (TCP Port 9090) abweichend eingetragen wurde.<br><br>
   
    <b>Optionen</b>
    <ul>
      <li><code>&lt;[RCC]&gt;</code>: Hier kann ein FHEM RCC Device angegeben werden mit dem der Server aufgeweckt und eingeschaltet werden kann.</li>
      <li><code>&lt;[WOL]&gt;</code>: Hier kann ein FHEM WOL Device angegeben werden mit dem der Server aufgeweckt und eingeschaltet werden kann.</li>
      <li><code>&lt;[PRESENCE]&gt;</code>: Hier kann ein FHEM PRESENCE Device angegeben werden mit dem die Erreichbarkeit des Servers &uuml;berpr&uuml;ft werden kann.</li>
      <li><code>&lt;username&gt;</code> and <code>&lt;password&gt;</code>: Falls der Server durch ein Passwort gesichert wurde, k&ouml;nnen hier die notwendigen Angaben f�r den Serverzugang angegeben werden.</li>
    </ul><br>
  </ul>
  <a name="SBserverset"></a>
  <b>Set</b>
  <ul>
    <code>set &lt;name&gt; &lt;command&gt;</code>
    <br><br>
    Dieses Modul unterst&uuml;tzt folgende SB_SERVER relevanten Befehle:<br><br>
    <ul>
      <li><b>abort</b> -  Bricht die Verbindung zum Server ab.</li>
      <li><b>addToFHEMUpdate</b> -  F&uuml;gt die Module dem FHEM-Update hinzu, muss nur einmalig ausgef&uuml;hrt werden.</li>
      <li><b>cliraw &lt;cli-command&gt;</b> -  Sendet einen CLI-Befehl an das LMS CLI</li>
      <li><b>on</b> -  Versucht den Server per WOL oder RCC einzuschalten.</li>
      <li><b>removeFromFHEMUpdate</b> -  Schlie&szlig;t die Module vom FHEM-Update aus.</li>
      <li><b>renew</b> -  Erneuert die Verbindung zum Server.</li>
      <li><b>rescan</b> -  Startet einen Scan der Musikbibliothek f&uuml;r alle im Server angegebenen Verzeichnisse.</li>
      <li><b>statusRequest</b> -  Aktualisiert die Readings von Server und konfigurierten Playern.</li>
    </ul>   
    <br>
  </ul>
  <a name="SBserverattr"></a>
  <b>Attribute</b>
  <ul>
    <li><code>alivetimer &lt;sec&gt;</code><br>
    Default 120. Alle &lt;sec&gt; Sekunden wird &uuml;berpr&uuml;ft, ob der Rechner mit dem LMS noch erreichbar ist
    - entweder �ber internen Ping (f&uuml;hrt zu regelm&auml;&szlig;igen H&auml;ngern von FHEM) oder PRESENCE (bevorzugt,
    keine H&auml;nger) - und ob der LMS noch l&auml;uft.</li>
    <li><code>doalivecheck &lt;true|false&gt;</code><br>
    &Uuml;berwachung des LMS ein- oder auschalten.</li>
    <li><code>httpport &lt;port&gt;</code><br>
    Im Normalfall ist der http-Port auf 9000 eingestellt. Sollte dies NICHT der Fall sein muss hier die ge&auml;nderte
    Portnummer eingetragen werden. Zur &Uuml;berpr&uuml;fung kann im Server unter Einstellungen � Erweitert �Netzwerk
    - Anschlussnummer des Webservers nachgeschlagen werden.</li>
    <li><a name="SBserver_attribut_ignoredIPs"><b><code>ignoredIPs &lt;IP-Adresse&gt;[,IP-Adresse]</code></b>
    </a><br />Mit diesem Attribut kann die automatische Erkennung dedizierter Ger&auml;te durch die Angabe derer IP-Adressen unterdr�ckt werden, z.B. "192.168.0.11,192.168.0.37"</li>
    <li><a name="SBserver_attribut_ignoredMACs"><b><code>ignoredMACs &lt;MAC-Adresse&gt;[,MAC-Adresse]</code></b>
    </a><br />Mit diesem Attribut kann die automatische Erkennung dedizierter Ger&auml;te durch die Angabe derer MAC-Adressen unterdr�ckt werden, z.B. "00:11:22:33:44:55,ff:ee:dd:cc:bb:aa"</li>
    <li><code>maxcmdstack &lt;Anzahl&gt;</code><br>
    Default ist der Stack auf eine Gr&ouml;&szlig;e von 200 eingestellt. Wenn die Verbindung zum LMS unterbrochen ist,
    werden bis zu &lt;Anzahl&gt; Befehle zwischengespeichert. Nach dem Verbindungsaufbau werden die Befehle,
    die nicht &auml;lter als 5 Minuten sind, an den LMS geschickt.</li>
    <li><code>maxfavorites &lt;Anzahl&gt;</code><br>
    Die maximale Anzahl der Favoriten wird hier eingestellt.</li>
  </ul>
</ul>
=end html_DE

=cut
