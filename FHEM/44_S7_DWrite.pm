# $Id: 44_S7_DWrite.pm 12776 2016-12-14 18:09:08Z charlie71born $
##############################################
package main;

use strict;
use warnings;

#use Switch;

my %sets = (
	"on"     => "",
	"off"    => "",
	"toggle" => ""
);

my %gets = (
	"reading" => "",
	"STATE"   => ""
);

#####################################
sub S7_DWrite_Initialize($) {
	my $hash = shift @_;

	# Provider

	# Consumer
	$hash->{Match} = "^DW";

	$hash->{DefFn}   = "S7_DWrite_Define";
	$hash->{UndefFn} = "S7_DWrite_Undef";
	$hash->{SetFn}   = "S7_DWrite_Set";

	$hash->{ParseFn} = "S7_DWrite_Parse";

	$hash->{AttrFn}   = "S7_DWrite_Attr";
	$hash->{AttrList} = "IODev trigger_length " . $readingFnAttributes;

	main::LoadModule("S7");
}

#####################################
sub S7_DWrite_Undef($$) {
	my ( $hash, $name ) = @_;
	RemoveInternalTimer($hash);
	Log3 $name, 4,
	    "S7_DWrite ("
	  . $hash->{IODev}{NAME}
	  . "): undef "
	  . $hash->{NAME}
	  . " Adress:"
	  . $hash->{ADDRESS};

	delete( $modules{S7_DWrite}{defptr} );

	return undef;
}

#####################################
sub S7_DWrite_Define($$) {
	my ( $hash, $def ) = @_;
	my @a = split( "[ \t][ \t]*", $def );

	my ( $name, $area, $DB, $position );
	my $byte;
	my $bit;

	$name = $a[0];
	Log3 $name, 5, "S7_DWrite_Define called";

	AssignIoPort($hash);    # logisches modul an physikalisches binden !!!

	my $sname = $hash->{IODev}{NAME};

	if ( uc $a[2] =~ m/^[QIMN](\d*)/ ) {
		$area = "db";
		$DB   = 0;
		my $startposition;
		my $Offset;

		if ( uc $a[2] =~ m/^Q(\d*)/ ) {
			$startposition = 1;
			if ( $hash->{IODev}{S7TYPE} eq "LOGO7" ) {
				$Offset = 942;
			}
			elsif ( $hash->{IODev}{S7TYPE} eq "LOGO8" ) {
				$Offset = 1064;
			}
			else {
				my $msg =
"wrong syntax : define <name> S7_DWrite {inputs|outputs|flags|db} <DB> <address> \n Only for Logo7 or Logo8:\n define <name> S7_DWrite {I|Q|M|NI|NQ}1..24";

				Log3 undef, 2, $msg;
				return $msg;
			}

		}
		elsif ( uc $a[2] =~ m/^I(\d*)/ ) {
			$startposition = 1;
			if ( $hash->{IODev}{S7TYPE} eq "LOGO7" ) {
				$Offset = 923;
			}
			elsif ( $hash->{IODev}{S7TYPE} eq "LOGO8" ) {
				$Offset = 1024;
			}
			else {
				my $msg =
"wrong syntax : define <name> S7_DWrite {inputs|outputs|flags|db} <DB> <address> \n Only for Logo7 or Logo8:\n define <name> S7_DWrite {I|Q|M|NI|NQ}1..24";

				Log3 undef, 2, $msg;
				return $msg;
			}
		}
		elsif ( uc $a[2] =~ m/^NI(\d*)/ ) {
			$startposition = 2;
			if ( $hash->{IODev}{S7TYPE} eq "LOGO8" ) {
				$Offset = 1246;
			}
			else {
				my $msg =
"wrong syntax : define <name> S7_DWrite {inputs|outputs|flags|db} <DB> <address> \n Only for Logo7 or Logo8:\n define <name> S7_DWrite {I|Q|M|NI|NQ}1..24";

				Log3 undef, 2, $msg;
				return $msg;
			}
		}
		elsif ( uc $a[2] =~ m/^NQ(\d*)/ ) {
			$startposition = 2;
			if ( $hash->{IODev}{S7TYPE} eq "LOGO8" ) {
				$Offset = 1390;
			}
			else {
				my $msg =
"wrong syntax : define <name> S7_DWrite {inputs|outputs|flags|db} <DB> <address> \n Only for Logo7 or Logo8:\n define <name> S7_DWrite {I|Q|M|NI|NQ}1..24";

				Log3 undef, 2, $msg;
				return $msg;
			}
		}
		elsif ( uc $a[2] =~ m/^M(\d*)/ ) {
			$startposition = 1;
			if ( $hash->{IODev}{S7TYPE} eq "LOGO7" ) {
				$Offset = 948;
			}
			elsif ( $hash->{IODev}{S7TYPE} eq "LOGO8" ) {
				$Offset = 1104;
			}
			else {
				my $msg =
"wrong syntax : define <name> S7_DWrite {inputs|outputs|flags|db} <DB> <address> \n Only for Logo7 or Logo8:\n define <name> S7_DWrite {I|Q|M|NI|NQ}1..24";

				Log3 undef, 2, $msg;
				return $msg;
			}
		}
		else {
			my $msg =
"wrong syntax : define <name> S7_DWrite {inputs|outputs|flags|db} <DB> <address> \n Only for Logo7 or Logo8:\n define <name> S7_DWrite {I|Q|M|NI|NQ}1..24";

			Log3 undef, 2, $msg;
			return $msg;
		}

		$position =
		  ( $Offset * 8 ) + int( substr( $a[2], $startposition ) ) - 1;
		$byte = int( $position / 8 );
		$bit  = ( $position % 8 );

	}
	else {
		$area     = lc $a[2];
		$DB       = $a[3];
		$position = $a[4];

		if (   $area ne "inputs"
			&& $area ne "outputs"
			&& $area ne "flags"
			&& $area ne "db" )
		{
			my $msg =
"wrong syntax: define <name> S7_DWrite {inputs|outputs|flags|db} <DB> <address>  \n Only for Logo7 or Logo8:\n define <name> S7_DWrite {I|Q|M}1..24";

			Log3 undef, 2, $msg;
			return $msg;
		}

		my @address = split( /\./, $position );
		if ( int(@address) == 2 ) {
			$byte = $address[0];
			$bit  = $address[1];
		}
		else {

			$byte = int( $address[0] / 8 );
			$bit  = ( $address[0] % 8 );
		}
		$position = ( $byte * 8 ) + $bit;
	}
	Log3 $name, 5, "S7_DWrite_Define called2";

	$hash->{ADDRESS} = "$byte.$bit";

	$hash->{AREA}     = $area;
	$hash->{DB}       = $DB;
	$hash->{LENGTH}   = 1;
	$hash->{POSITION} = $position;

	my $ID = "$area $DB";

	if ( !defined( $modules{S7_DWrite}{defptr}{$ID} ) ) {
		my @b = ();
		push( @b, $hash );
		$modules{S7_DWrite}{defptr}{$ID} = \@b;

	}
	else {
		push( @{ $modules{S7_DWrite}{defptr}{$ID} }, $hash );
	}

	$hash->{IODev}{dirty} = 1;
	return undef;
}

#####################################

sub S7_DWrite_setABit($$) {
	my ( $hash, $newValue ) = @_;

	my $name = $hash->{NAME};
	$newValue = lc $newValue;
	Log3 $name, 4, "S7_DWrite_setABit $newValue";

	if ( $newValue ne "on" && $newValue ne "off" && $newValue ne "trigger" ) {
		return "Unknown argument $newValue, choose one of  ON OFF TRIGGER";
	}

	my $sname    = $hash->{IODev}{NAME};
	my $position = $hash->{POSITION};
	my $area     = $hash->{AREA};
	my $dbNR     = $hash->{DB};
	my $shash    = $defs{$sname};

	my $writeAreaIndex = S7_getAreaIndex4AreaName($area);
	return $writeAreaIndex if ( $writeAreaIndex ne int($writeAreaIndex) );

	my $b = 0;
	my $res;

	if ( $newValue eq "on" || $newValue eq "trigger" ) {
		$b = 1;
	}
	if ( $shash->{S7TYPE} eq "S5" ) {

		#S5
		#lesen wir das aktuelle byte
		my $byte = int( $position / 8 );
		my $bit  = int( $position % 8 );
		my $readbuffer;
		( $res, $readbuffer ) =
		  S7_ReadBlockFromPLC( $shash, $writeAreaIndex, $dbNR, $byte, 1 );

		if ( $res == 0 && length($readbuffer) == 1 ) {    #reading was OK
			    #setzen/löschen wir das gewünsche bit
			    
			my $tbuffer = join( ", ", unpack( "H2 " x length($readbuffer), $readbuffer ) );
			Log3( undef, 5, "S5 Read old Value <-- " . $tbuffer ." now changing bitNr: ".$bit );
			
			
			my @cbuffer = unpack( "C" x length($readbuffer), $readbuffer);
			if ($b == 1) {
				$cbuffer[0] |= (1 << $bit);				
			} else {
				$cbuffer[0] &= (~(1 << $bit)) & 0xFF;
			}
			
			$readbuffer = pack( "C" x 1, @cbuffer);
						

			#schreiben wir das byte
			$tbuffer = join( ", ", unpack( "H2 " x length($readbuffer), $readbuffer ) );
			Log3( undef, 5, "S5 Write new Value <-- " . $tbuffer );
			$res = S7_WriteToPLC( $shash, $writeAreaIndex, $dbNR, $byte,  &S7Client::S7WLByte , $readbuffer );
			
			


			if ( $res != 0 ) {
				my $error = $shash->{S7PLCClient}->getErrorStr($res);				
				my $msg =
				  "$name S7_DWrite_setABit -S5- S7_WriteToPLC error: $res=$error";
				Log3( $name, 3, $msg );
			}
				
			
			} else {

				my $error = $shash->{S7PLCClient}->getErrorStr($res);
				my $msg =
				  "$name S7_DWrite_setABit -S5- ReadArea error: $res=$error";
				Log3( $name, 3, $msg );

				S7_reconnect($shash);    #lets try a reconnect
				return ( -2, $msg );
			}

		}
		else {

			#S7
			$res =
			  S7_WriteBitToPLC( $shash, $writeAreaIndex, $dbNR, $position, $b );
		}

		if ( $res == 0 ) {
			main::readingsSingleUpdate( $hash, "state", $newValue, 1 );
		}
		else {
			main::readingsSingleUpdate( $hash, "state", "", 1 );
		}

		if ( $newValue eq "trigger" ) {

			my $triggerLength = 1;
			if ( defined( $main::attr{$name}{trigger_length} ) ) {
				$triggerLength = $main::attr{$name}{trigger_length};
			}

			InternalTimer( gettimeofday() + $triggerLength,
				"S7_DWrite_SwitchOff", $hash, 1 );
		}

		return undef;

	}

#####################################

	sub S7_DWrite_Set(@) {
		my ( $hash, @a ) = @_;

		return "Need at least one parameter" if ( int(@a) < 2 );
		return S7_DWrite_setABit( $hash, $a[1] );

	}

#####################################

	sub S7_DWrite_SwitchOff($) {
		my ($hash) = @_;
		my $name = $hash->{NAME};
		Log3 $name, 4, "S7_DWrite: GetUpdate called ...";

		return S7_DWrite_setABit( $hash, "off" );

	}

#####################################

	sub S7_DWrite_Parse($$) {
		my ( $hash, $rmsg ) = @_;
		my $name;

		if ( defined( $hash->{NAME} ) ) {
			$name = $hash->{NAME};
		}
		else {
			$name = "dummy";
			Log3 undef, 2, "S7_DWrite_Parse: Error ...";
			return undef;
		}

		my @a = split( "[ \t][ \t]*", $rmsg );
		my @list;

		my ( $area, $DB, $start, $length, $datatype, $s7name, $hexbuffer,
			$clientNames );

		$area        = lc $a[1];
		$DB          = $a[2];
		$start       = $a[3];
		$length      = $a[4];
		$s7name      = $a[5];
		$hexbuffer   = $a[6];
		$clientNames = $a[7];

		my $ID = "$area $DB";

		Log3 $name, 6, "$name S7_DWrite_Parse $rmsg";
		my @clientList = split( ",", $clientNames );

		if ( int(@clientList) > 0 ) {
			my @Writebuffer = unpack( "C" x $length,
				pack( "H2" x $length, split( ",", $hexbuffer ) ) );
			foreach my $clientName (@clientList) {

				my $h = $defs{$clientName};

				if (   $h->{TYPE} eq "S7_DWrite"
					&& $start <= int( $h->{POSITION} / 8 )
					&& $start + $length >= int( $h->{POSITION} / 8 ) )
				{
					push( @list, $clientName )
					  ;    #damit die werte im client gesetzt werden!

					#aktualisierung des wertes
					my $s = int( $h->{POSITION} / 8 ) - $start;

					my $myI = $hash->{S7PLCClient}->ByteAt( \@Writebuffer, $s );

					Log3 $name, 5, "$name S7_DWrite_Parse update $clientName ";

					if ( ( int($myI) & ( 1 << ( $h->{POSITION} % 8 ) ) ) > 0 ) {

						main::readingsSingleUpdate( $h, "state", "on", 1 );

					}
					else {
						main::readingsSingleUpdate( $h, "state", "off", 1 );

					}
				}

				#			}
			}
		}
		else {
			Log3 $name, 3, "$name S7_DWrite_Parse going the save way ";

			if ( defined( $modules{S7_DWrite}{defptr}{$ID} ) ) {

				foreach my $h ( @{ $modules{S7_DWrite}{defptr}{$ID} } ) {
					if ( defined( $main::attr{ $h->{NAME} }{IODev} )
						&& $main::attr{ $h->{NAME} }{IODev} eq $name )
					{
						if (   $start <= int( $h->{POSITION} / 8 )
							&& $start + $length >= int( $h->{POSITION} / 8 ) )
						{

							my $n = $h
							  ->{NAME}; #damit die werte im client gesetzt werden!
							push( @list, $n );

							#aktualisierung des wertes
							my @Writebuffer = unpack(
								"C" x $length,
								pack(
									"H2" x $length, split( ",", $hexbuffer )
								)
							);
							my $s = int( $h->{POSITION} / 8 ) - $start;

							#						my $b = pack( "C" x $length, @Writebuffer );

							my $myI =
							  $hash->{S7PLCClient}->ByteAt( \@Writebuffer, $s );

							Log3 $name, 6, "$name S7_DWrite_Parse update $n ";

							if ( ( int($myI) & ( 1 << ( $h->{POSITION} % 8 ) ) )
								> 0 )
							{

								main::readingsSingleUpdate( $h, "state", "on",
									1 );

							}
							else {

								main::readingsSingleUpdate( $h, "state", "off",
									1 );

							}
						}
					}

				}
			}
		}

		if ( int(@list) == 0 ) {
			Log3 $name, 6, "S7_DWrite: Parse no client found ($name) ...";
			push( @list, "" );
		}

		return @list;

	}
#####################################

	sub S7_DWrite_Attr(@) {
		my ( $cmd, $name, $aName, $aVal ) = @_;

		# $cmd can be "del" or "set"
		# $name is device name
		# aName and aVal are Attribute name and value
		my $hash = $defs{$name};
		if ( $cmd eq "set" ) {
			if ( $aName eq "trigger_length" ) {
				if ( $aVal ne int($aVal) ) {
					Log3 $name, 3,
"S7_DWrite: Invalid $aName in attr $name $aName ($aVal is not a number): $@";
					return "Invalid $aName : $aVal is not a number";
				}

			}
			elsif ( $aName eq "IODev" ) {
				Log3 $name, 4, "S7_DWrite: IODev for $name is $aVal";
				$hash->{IODev}{dirty} = 1;
			}

		}
		return undef;
	}

	1;

=pod
=item summary logical device for a digital writing to a S7/S5
=item summary_DE logisches Device für einen binären Lese/Schreib Datenpunkt zu einer S5 / S7
=begin html

<p><a name="S7_DWrite"></a></p>
<h3>S7_DWrite</h3>
<ul>
<ul>This module is a logical module of the physical module S7.</ul>
</ul>
<ul>
<ul>This module is used to set/unset a Bit in ad DB of the PLC.</ul>
</ul>
<ul>
<ul>Note: you have to configure a PLC writing at the physical modul (S7) first.</ul>
</ul>
<p><br /><br /><br /><strong>Define</strong><code>define &lt;name&gt; S7_DWrite {db} &lt;DB&gt; &lt;address&gt;</code></p>
<ul>
<ul>
<ul>
<ul>
<li>db &hellip; defines where to read. Note currently only writing in to DB are supported.</li>
<li>DB &hellip; Number of the DB</li>
<li>address &hellip; address you want to write. bit number to read. Example: 10.6</li>
</ul>
Note: the required memory area need to be with in the configured PLC reading of the physical module.</ul>
</ul>
</ul>
<p><strong>Set</strong><code>set &lt;name&gt; S7_AWrite {ON|OFF|TRIGGER};</code></p>
<ul>
<ul>Note: TRIGGER sets the bit for 1s to ON than it will set to OFF.</ul>
</ul>
<p><strong>Attr</strong><br /> The following parameters are used to scale every reading</p>
<ul>
<li>trigger_length ... sets the on-time of a trigger</li>
</ul>
=end html

=begin html_DE

<p><a name="S7_DWrite"></a></p>
<h3>S7_DWrite</h3>
<ul>
<ul>This module is a logical module of the physical module S7.</ul>
</ul>
<ul>
<ul>This module is used to set/unset a Bit in ad DB of the PLC.</ul>
</ul>
<ul>
<ul>Note: you have to configure a PLC writing at the physical modul (S7) first.</ul>
</ul>
<p><br /><br /><br /><strong>Define</strong><code>define &lt;name&gt; S7_DWrite {db} &lt;DB&gt; &lt;position&gt;</code></p>
<ul>
<ul>
<ul>
<ul>
<li>db &hellip; defines where to read. Note currently only writing in to DB are supported.</li>
<li>DB &hellip; Number of the DB</li>
<li>address &hellip; address you want to write. bit number to read. Example: 10.6</li>
</ul>
Note: the required memory area need to be with in the configured PLC reading of the physical module.</ul>
</ul>
</ul>
<p><br /><strong>Set</strong><code>set &lt;name&gt; S7_AWrite {ON|OFF|TRIGGER};</code></p>
<ul>
<ul>Note: TRIGGER sets the bit for 1s to ON than it will set to OFF.</ul>
</ul>
<p><strong>Attr</strong><br /> The following parameters are used to scale every reading</p>
<ul>
<li>trigger_length ... sets the on-time of a trigger</li>
</ul>
=end html_DE

=cut

