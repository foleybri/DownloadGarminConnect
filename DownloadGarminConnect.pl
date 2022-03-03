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

# use LWP::ConsoleLogger::Everywhere ();

#
# This script downloads raw .json and .gpx files from https://connect.garmin.com to your local computer
# Downloads are incremental, so only new exercises since your last backup will be downloaded
# The login scheme used by garmin connect is: https://en.wikipedia.org/wiki/Central_Authentication_Service
# API Documentation from Garmin:
# * https://connect.garmin.com/proxy/activity-search-service-1.2/
# * https://connect.garmin.com/proxy/activity-service-1.3/

my %login_params = (
    service                         => 'https://connect.garmin.com/modern/',
    webhost                         => 'https://connect.garmin.com/modern/',
    source                          => 'https://connect.garmin.com/signin/',
    redirectAfterAccountLoginUrl    => 'https://connect.garmin.com/modern/',
    redirectAfterAccountCreationUrl => 'https://connect.garmin.com/modern/',
    gauthHost                       => 'https://sso.garmin.com/sso',
    locale                          => 'en_GB',
    id                              => 'gauth-widget',
    cssUrl                          => 'https://connect.garmin.com/gauth-custom-v1.2-min.css',
    privacyStatementUrl             => 'https://www.garmin.com/en-GB/privacy/connect/',
    clientId                        => 'GarminConnect',
    rememberMeShown                 => 'true',
    rememberMeChecked               => 'false',
    createAccountShown              => 'true',
    openCreateAccount               => 'false',
    displayNameShown                => 'false',
    consumeServiceTicket            => 'false',
    initialFocus                    => 'true',
    embedWidget                     => 'false',
    socialEnabled                   => 'false',
    generateExtraServiceTicket      => 'true',
    generateTwoExtraServiceTickets  => 'true',
    generateNoServiceTicket         => 'false',
    globalOptInShown                => 'true',
    globalOptInChecked              => 'false',
    mobile                          => 'false',
    connectLegalTerms               => 'true',
    showTermsOfUse                  => 'false',
    showPrivacyPolicy               => 'false',
    showConnectLegalAge             => 'false',
    locationPromptShown             => 'true',
    showPassword                    => 'true',
    useCustomHeader                 => 'false',
    mfaRequired                     => 'false',
    performMFACheck                 => 'false',
    rememberMyBrowserShown          => 'true',
    rememberMyBrowserChecked        => 'false'
);

my $signin_page = 'https://connect.garmin.com/signin/';
my $sso_page    = 'https://sso.garmin.com/sso/signin';
my $modern_page = 'https://connect.garmin.com/modern/';

my $backup_location = '/data/Brian/Garmin';    # Activities will be stored in yyyy/mm directory structure beneath this location
my $garmin_username = 'brianf@sindar.net';
my $garmin_password = '';                      # Prompted for below
my $batch_size      = 25;

my $url_gc_search          = 'https://connect.garmin.com/proxy/activitylist-service/activities/search/activities?';
my $url_gc_gpx_activity    = 'https://connect.garmin.com/proxy/download-service/export/gpx/activity/%d';
my $url_gc_activity        = 'https://connect.garmin.com/proxy/activity-service/activity/%d';
my $url_gc_activityDetails = 'https://connect.garmin.com/proxy/activity-service/activity/%d/details';
my $url_gc_activitySplits  = 'https://connect.garmin.com/proxy/activity-service/activity/%d/splits';

if ( !-d $backup_location ) {
    croak "$backup_location does not exist\n";
}

ReadMode( 'noecho' );
print "Enter Password: ";
chomp( $garmin_password = <STDIN> );
ReadMode( 'restore' );

sub makeHttpRequest {
    my ( $ua, $url, $action, $skipFailure, $postParams, $getParams ) = @_;

    print( $action . "...\n" );
    print( $url . "\n" );
    sleep( 1 );    # Throttle requests so as not to overload garmin
    my $response;
    if ( defined $postParams ) {
        $response = $ua->post( $url, $postParams );
    }
    elsif ( defined $getParams ) {
        $response = $ua->get( $url, $getParams, Referer => $signin_page );
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

my $full_url = URI->new( $sso_page );
$full_url->query_form( %login_params );

my $resp = $ua->get( $full_url, Referer => $signin_page );

my $csrf = '';
if ( $resp->content =~ /.*name="_csrf" value="([^"]*)".*/ ) {
    $csrf = $1;
    print 'CSRF: ' . $csrf . "\n";
}
else {
    croak 'Could not find csrf';
}

my $resp2 = $ua->post( $full_url, Referer => $full_url, 'Content-Type' => 'application/x-www-form-urlencoded', Content => { username => $garmin_username, password => $garmin_password, embed => 'false', _csrf => $csrf } );

my $service_ticket = '';
if ( $resp2->content =~ /.*(ST-[^-]+-[^-]+-cas).*/ ) {
    $service_ticket = $1;
    print 'Service Ticket: ' . $service_ticket . "\n";
}
else {
    croak 'Could not find service ticket';
}

my $m = URI->new( $modern_page );
$m->query_form( ticket => $service_ticket );
my $resp3 = $ua->get( $m, Referer => $full_url );

my $downloaded = 0;
while ( 1 ) {
    my $response = makeHttpRequest( $ua, $url_gc_search . 'start=' . $downloaded . '&limit=' . $batch_size, 'Search for activity batch', 0 );
    my $results  = $json->decode( $response );

    if ( scalar @$results <= 0 ) {
        last;
    }

    foreach my $a ( @$results ) {
        my $id = $a->{ activityId };
        printf( "%d %s id: %s, name: %s, type: %s\n", $downloaded + 1, $a->{ startTimeLocal }, $id, $a->{ activityName }, $a->{ activityType }->{ typeKey } );

        my $date = $a->{ startTimeLocal };
        my ( $year, $month, $day ) = split( /-/x, $date );
        my $path = sprintf '%s/%d/%02d', $backup_location, $year, $month;
        make_path( $path );
        chdir( $path );

        my $json_file    = sprintf( '%s/%d.json',         $path, $id );
        my $details_file = sprintf( '%s/%d-details.json', $path, $id );
        my $splits_file  = sprintf( '%s/%d-splits.json',  $path, $id );
        my $gpx_file              = sprintf '%s/%d.gpx', $path, $id;
        my $requires_gpx_download = 0;

        if ( !-f $json_file ) {
            $requires_gpx_download = 1;
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
            $requires_gpx_download = 1;
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
            $requires_gpx_download = 1;
            my $activity_splits_url = sprintf $url_gc_activitySplits, $id;
            $response = makeHttpRequest( $ua, $activity_splits_url, 'Downloading: ' . $activity_splits_url . ' => ' . $splits_file, 1 );
            if ( length $response ) {
                my $activity_splits = $json->decode( $response );

                open my $fh, ">", $splits_file or croak 'Could not open ' . $splits_file . "\n";
                print $fh $json->pretty->encode( $activity_splits );
                close $fh or croak 'Could not close ' . $splits_file . "\n";
            }
        }

        if ( $requires_gpx_download && !-f $gpx_file ) {
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
