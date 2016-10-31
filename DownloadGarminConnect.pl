#!/usr/bin/perl
use 5.006;
use warnings FATAL => 'all';
use strict;
use Carp;
use LWP::UserAgent;
use URI;
use JSON;
use File::Path qw(make_path);
use String::ShellQuote;
use Term::ReadKey;

#
# This script downloads raw .json and .gpx files from https://connect.garmin.com to your local computer
# Downloads are incremental, so only new exercises since your last backup will be downloaded
# The login scheme used by garmin connect is: https://en.wikipedia.org/wiki/Central_Authentication_Service
# API Documentation from Garmin:
# * https://connect.garmin.com/proxy/activity-search-service-1.2/
# * https://connect.garmin.com/proxy/activity-service-1.3/
#

my $backup_location = '/data/Brian/Garmin';    # Activities will be stored in yyyy/mm directory structure beneath this location
my $garmin_username = 'brianf@sindar.net';
my $garmin_password = '';                      # Prompted for below
my $batch_size      = 25;
my $url_gc_login =
'https://sso.garmin.com/sso/login?service=https%3A%2F%2Fconnect.garmin.com%2Fpost-auth%2Flogin&webhost=olaxpw-connect04&source=https%3A%2F%2Fconnect.garmin.com%2Fen-US%2Fsignin&redirectAfterAccountLoginUrl=https%3A%2F%2Fconnect.garmin.com%2Fpost-auth%2Flogin&redirectAfterAccountCreationUrl=https%3A%2F%2Fconnect.garmin.com%2Fpost-auth%2Flogin&gauthHost=https%3A%2F%2Fsso.garmin.com%2Fsso&locale=en_US&id=gauth-widget&cssUrl=https%3A%2F%2Fstatic.garmincdn.com%2Fcom.garmin.connect%2Fui%2Fcss%2Fgauth-custom-v1.1-min.css&clientId=GarminConnect&rememberMeShown=true&rememberMeChecked=false&createAccountShown=true&openCreateAccount=false&usernameShown=false&displayNameShown=false&consumeServiceTicket=false&initialFocus=true&embedWidget=false&generateExtraServiceTicket=false';
my $url_gc_post_auth       = 'https://connect.garmin.com/post-auth/login?';
my $url_gc_search          = 'https://connect.garmin.com/proxy/activity-search-service-1.2/json/activities?';
my $url_gc_gpx_activity    = 'https://connect.garmin.com/modern/proxy/download-service/export/gpx/activity/%d';
my $url_gc_activity        = 'https://connect.garmin.com/modern/proxy/activity-service/activity/%d';
my $url_gc_activityDetails = 'https://connect.garmin.com/modern/proxy/activity-service/activity/%d/details';
my $url_gc_activitySplits  = 'https://connect.garmin.com/modern/proxy/activity-service/activity/%d/splits';

if ( !-d $backup_location ) {
    croak "$backup_location does not exist\n";
}

ReadMode( 'noecho' );
print "Enter Password: ";
chomp( $garmin_password = <STDIN> );
ReadMode( 'restore' );

sub makeHttpRequest {
    my ( $ua, $url, $action, $skipFailure, $postParams ) = @_;

    print( $action . "...\n" );
    sleep( 1 );    # Throttle requests so as not to overload garmin
    my $response;
    if ( defined $postParams ) {
        $response = $ua->post( $url, $postParams );
    }
    else {
        $response = $ua->get( $url );
    }

    if ( $response->is_redirect ) {
        print 'n redirects: ' . $response->redirects . "\n";
    }

    if ( $response->is_success ) {
        return $response->content;
    }
    elsif ( $skipFailure ) {
        print 'Error while ' . $action . '. ' . $response->status_line . "\n";
        return '';
    }
    else {
        croak 'Error while ' . $action . '. ' . $response->status_line . '. ' . $response->content;
        return '';
    }
}

my $ua = LWP::UserAgent->new(
    agent                 => 'Mozilla/5.0 (X11; Ubuntu; Linux x86_64; rv:42.0) Gecko/20100101 Firefox/42.0',
    cookie_jar            => {},
    requests_redirectable => [ 'GET', 'HEAD', 'POST' ],
    max_redirect          => 14,                                                                               # Needed due to many redirects during login to garmin
);
my $json = JSON->new();

makeHttpRequest( $ua, $url_gc_login, 'Hitting login page for the first time', 0 );
my $login_response = makeHttpRequest(
    $ua,
    $url_gc_login,
    'Entering username and password on login page',
    0,
    {
        username            => $garmin_username,
        password            => $garmin_password,
        embed               => "true",
        lt                  => 'e1s1',
        _eventId            => "submit",
        displayNameRequired => 'false',
    }
);

my $service_ticket = '';
if ( $login_response =~ /.*(ST-[^-]+-[^-]+-cas).*/ ) {
    $service_ticket = $1;
}

makeHttpRequest( $ua, $url_gc_post_auth . 'ticket=' . $service_ticket, 'Posting login ticket to garmin', 0 );

my $response = makeHttpRequest( $ua, $url_gc_search . 'start=0&limit=1', 'Searching for activity count', 0 );
my $results  = $json->decode( $response );
my $total    = $results->{ results }->{ totalFound };
printf( "Found %d activities\n", $total );

my $downloaded      = 0;
my $num_to_download = 0;

while ( $downloaded < $total ) {
    if ( $total - $downloaded > $batch_size ) {
        $num_to_download = $batch_size;
    }
    else {
        $num_to_download = $total - $downloaded;
    }

    $response = makeHttpRequest( $ua, $url_gc_search . 'start=' . $downloaded . '&limit=' . $num_to_download, 'Search for activity batch', 0 );
    $results = $json->decode( $response );

    my $activities = $results->{ results }->{ activities };
    foreach my $activity ( @$activities ) {
        my $a  = $activity->{ activity };
        my $id = $a->{ activityId };
        printf( "%d/%d %s id: %s, name: %s, type: %s\n", $downloaded + 1, $total, $a->{ activitySummary }->{ BeginTimestamp }->{ display }, $id, $a->{ activityName }, $a->{ activityType }->{ display } );

        my $date = $a->{ activitySummary }->{ BeginTimestamp }->{ value };
        my ( $year, $month, $day ) = split( /-/x, $date );
        my $path = sprintf '%s/%d/%02d', $backup_location, $year, $month;
        make_path( $path );
        chdir( $path );

        my $json_file    = sprintf( '%s/%d.json',         $path, $id );
        my $details_file = sprintf( '%s/%d-details.json', $path, $id );
        my $splits_file  = sprintf( '%s/%d-splits.json',  $path, $id );
        my $gpx_file = sprintf '%s/%d.gpx', $path, $id;

        if ( !-f $json_file ) {
            my $activity_url = sprintf $url_gc_activity, $id;
            $response = makeHttpRequest( $ua, $activity_url, 'Downloading: ' . $activity_url . ' => ' . $json_file, 1 );
            if ( length $response ) {
                my $activity = $json->decode( $response );

                open my $fh, ">", $json_file or croak 'Could not open ' . $json_file . "\n";
                print $fh $json->pretty->encode( $activity );
                close $fh or croak 'Could not close ' . $json_file . "\n";
            }
        }

        if ( !-f $details_file ) {
            my $activity_details_url = sprintf $url_gc_activityDetails, $id;
            $response = makeHttpRequest( $ua, $activity_details_url, 'Downloading: ' . $activity_details_url . ' => ' . $details_file, 1 );
            if ( length $response ) {
                my $activity_details = $json->decode( $response );

                open my $fh, ">", $details_file or croak 'Could not open ' . $details_file . "\n";
                print $fh $json->pretty->encode( $activity_details );
                close $fh or croak 'Could not close ' . $details_file . "\n";
            }
        }

        if ( !-f $splits_file ) {
            my $activity_splits_url = sprintf $url_gc_activitySplits, $id;
            $response = makeHttpRequest( $ua, $activity_splits_url, 'Downloading: ' . $activity_splits_url . ' => ' . $splits_file, 1 );
            if ( length $response ) {
                my $activity_splits = $json->decode( $response );

                open my $fh, ">", $splits_file or croak 'Could not open ' . $splits_file . "\n";
                print $fh $json->pretty->encode( $activity_splits );
                close $fh or croak 'Could not close ' . $splits_file . "\n";
            }
        }

        if ( !-f $gpx_file ) {
            my $activity_gpx_url = sprintf $url_gc_gpx_activity, $id;
            $response = makeHttpRequest( $ua, $activity_gpx_url, 'Downloading: ' . $activity_gpx_url . ' => ' . $gpx_file, 1 );

            if ( length $response ) {
                open my $fh, ">", $gpx_file or croak 'Could not open ' . $gpx_file . "\n";
                print $fh $response;
                close $fh or croak 'Could not close ' . $gpx_file . "\n";
            }
        }
        $downloaded++;
    }
}
