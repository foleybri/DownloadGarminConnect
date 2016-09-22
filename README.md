## Synopsis

A simple perl script to download exercise data from https://connect.garmin.com

## Usage

* Edit the script to set `$backup_location` and `$garmin_username` to appropriate values
* Run the script: `perl DownloadGarminConnect.pl`
* You will be prompted for your garmin connect password
* Exercise data will appear in: `$backup_location`/yyyy/mm/ folders

## Motivation

This script downloads raw .json and .gpx files to your local computer.  These can then be included in your normal backups, so that you are never in danger of losing access to your garmin data.

The .gpx files should be immediately importable to other software.  I have a future project in mind to provide a browser for garmin's .json files.

## API Reference

* https://connect.garmin.com/proxy/activity-search-service-1.2/
* https://connect.garmin.com/proxy/activity-service-1.3/

## Author

Brian Foley <brianf@sindar.net>
