package FixMyStreet::Util;

use Error qw(:try);
use LWP::Simple;
use mySociety::Config;
use mySociety::Locale;

# Nearest things

sub find_closest {
    my ($latitude, $longitude) = @_;
    my $str = '';

    # Get nearest road-type thing from Bing
    my $bingkey;
    try {
        $bingkey = mySociety::Config::get('BING_MAPS_API_KEY');
    } otherwise {
        my $e = shift;
        # Ignoring missing BING key, it is optional.
    };
    if ($bingkey) {
        my $url = "http://dev.virtualearth.net/REST/v1/Locations/$latitude,$longitude?c=en-GB&key=$bingkey";
        my $j = LWP::Simple::get($url);
        if ($j) {
            $j = JSON->new->utf8->allow_nonref->decode($j);
            if ($j->{resourceSets}[0]{resources}[0]{name}) {
                $str .= sprintf(_("Nearest road to the pin placed on the map (automatically generated by Bing Maps): %s\n\n"),
                                $j->{resourceSets}[0]{resources}[0]{name});
            }
        }
    }

    # Get nearest postcode from Matthew's random gazetteer (put in MaPit? Or elsewhere?)
    my $url = "http://gazetteer.dracos.vm.bytemark.co.uk/point/$latitude,$longitude.json";
    my $j = LWP::Simple::get($url);
    if ($j) {
        $j = JSON->new->utf8->allow_nonref->decode($j);
        if ($j->{postcode}) {
            $str .= sprintf(_("Nearest postcode to the pin placed on the map (automatically generated): %s (%sm away)\n\n"),
                            $j->{postcode}[0], $j->{postcode}[1]);
        }
    }
    if ( mySociety::Config::get('MAP_TYPE') eq 'OSM' ) {
        my $osmtags =
            FixMyStreet::Geocode::OSM::get_nearest_road_tags($latitude,
                                                             $longitude);
        if ($osmtags) {
            my ($name, $ref) = ('','');
            $name =  $osmtags->{name} if exists $osmtags->{name};
            $ref = " ($osmtags->{ref})" if exists $osmtags->{ref};
            if ($name || $ref) {
                $str .= sprintf(_("Nearest named road to the pin placed on the map (automatically generated using OpenStreetmap): %s%s\n\n"),
                                $name, $ref);

                if (my $operator = $osmtags->{operator}) {
                    $str .= sprintf(_("Road operator for this named road (from OpenStreetmap): %s\n\n"),
                                    $operator);
                } elsif ($operator = $osmtags->{operatorguess}) {
                    $str .= sprintf(_("Road operator for this named road (guessed from road reference number and type): %s\n\n"),
                                    $operator);
                }
            }
        }
    }
    return $str;
}

1;
