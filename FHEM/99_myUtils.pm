##############################################
# $Id: myUtilsTemplate.pm 7570 2015-01-14 18:31:44Z rudolfkoenig $
#
# Save this file as 99_myUtils.pm, and create your own functions in the new
# file. They are then available in every Perl expression.

package main;

use strict;
use warnings;
use POSIX;
use Date::Parse;

sub
myUtils_Initialize($$)
{
  my ($hash) = @_;
}

# Enter you functions below _this_ line.

sub 
sendStatusMessage($) {
  my $temperature = ReadingsVal("labra_THS", "temperature", "");
  my $humidity = ReadingsVal("labra_THS", "humidity", "");
  my $window = ucfirst(ReadingsVal("key_1", "state", ""));
  my $peer = ReadingsVal("telegramBot", "msgPeerId", "");
  my $away = ucfirst(ReadingsVal("awayMode", "state", ""));
  fhem("set telegramBot message @".$peer." Window: ".$window." \n"."Temperature: ".$temperature." °C\n"."Humidity: ".$humidity."% rH\nAway Mode is ".$away."\n");
  return;
}

sub
turnRoomLightsOnRemotelyTg($) {
  fhem("set HM_3F8FDA on");
}

sub
turnRoomLightsOffRemotelyTg($) {
  fhem("set HM_3F8FDA off");
}

sub
turnAllLightsOnRemotelyTg($) {
  fhem("set HM_3F8FDA on");
  fhem("set HM_5AA889_Sw on");
}

sub
turnAllLightsOffRemotelyTg($) {
  fhem("set HM_3F8FDA off");
  fhem("set HM_5AA889_Sw off");
}

sub
countKeyHolders {
  my @keyHolders = @_;
  my $khCounter = 0;
  my $kh;
  my $light;
  my @lights = ("HM_3F8FDA", "HM_5AA889_Sw");
  foreach $kh (@keyHolders) {
    if (ReadingsVal($kh,"state","") eq "closed") {
      $khCounter++;
    }
  }
  if ($khCounter == 0) {
    foreach $light (@lights) {
      fhem("set ".$light." off");
    }
  }
  return;
}

sub
checkRoomLight {
  my ($keyHolder,$lightSensor,$light) = @_;
  if (ReadingsVal($keyHolder,"state","") eq "closed") {
    fhem("set ".$light." ".ReadingsVal($lightSensor,"state",""));
  }
  return;
}

sub
checkLaundry {
  my $laundryPower = ReadingsVal("HM_3F8FDA", "state", "");
  my @bookings = fhem("get LaundryCalendar events");
  if ($laundryPower eq "on") {
    if ($bookings[0] eq "") {
      fhem("set HM_3F8FDA off");
    }
  }
  if ($laundryPower eq "off") {
    if ($bookings[0] ne "") {
      fhem("set HM_3F8FDA on");
    }
  }
}

sub
sendLivePhoto {
  my $peer = ReadingsVal("telegramBot", "msgPeerId", "");
  fhem("get ipcam image");
  fhem("define a5 at +00:00:01 set telegramBot sendImage @".$peer." \"ipcam_snapshot.jpg\"");
}

sub
toggleAwayMode {
  my $peer = ReadingsVal("telegramBot", "msgPeerId", "");
  if (ReadingsVal("awayMode", "state", "") eq "on") {
    fhem("set awayMode off");
    fhem("set telegramBot message @".$peer." Away mode is Off");
  }
  else {
    fhem("set awayMode on");
    fhem("set telegramBot message @".$peer." Away mode is On");
  }
}

sub
getMotionLevel {
  my $away = ReadingsVal("awayMode", "state", "");
  if ($away eq "on") {
    my $peer = ReadingsVal("telegramBot", "msgPeerId", "");
    my $body = InternalVal("motionDetect", "buf", "");
    print {*STDOUT} $body;
    if ($body =~ /level=((1[5-9])|([2-9][0-9])|100)/) {
      fhem("get ipcam image");
      fhem("define a5 at +00:00:01 set telegramBot sendImage @".$peer." \"ipcam_snapshot.jpg\"");
    }
  }
  
}
