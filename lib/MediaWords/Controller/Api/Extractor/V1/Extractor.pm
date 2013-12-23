package MediaWords::Controller::Api::Extractor::V1::Extractor;
use Modern::Perl "2013";
use MediaWords::CommonLibs;

use MediaWords::DBI::StorySubsets;

use strict;
use warnings;
use base 'Catalyst::Controller';
use JSON;
use List::Util qw(first max maxstr min minstr reduce shuffle sum);
use Moose;
use namespace::autoclean;
use List::Compare;
use Carp;
use MediaWords::Crawler::Extractor;
use MediaWords::DBI::Downloads;

=head1 NAME

MediaWords::Controller::Stories - Catalyst Controller

=head1 DESCRIPTION

Catalyst Controller.

=head1 METHODS

=cut

=head2 index 

=cut

BEGIN { extends 'Catalyst::Controller::REST' }

__PACKAGE__->config(
    'default'   => 'application/json',
    'stash_key' => 'rest',
    'map'       => {

        #	   'text/html'          => 'YAML::HTML',
        'text/xml' => 'XML::Simple',

        # #         'text/x-yaml'        => 'YAML',
        'application/json'         => 'JSON',
        'text/x-json'              => 'JSON',
        'text/x-data-dumper'       => [ 'Data::Serializer', 'Data::Dumper' ],
        'text/x-data-denter'       => [ 'Data::Serializer', 'Data::Denter' ],
        'text/x-data-taxi'         => [ 'Data::Serializer', 'Data::Taxi' ],
        'application/x-storable'   => [ 'Data::Serializer', 'Storable' ],
        'application/x-freezethaw' => [ 'Data::Serializer', 'FreezeThaw' ],
        'text/x-config-general'    => [ 'Data::Serializer', 'Config::General' ],
        'text/x-php-serialization' => [ 'Data::Serializer', 'PHP::Serialization' ],
    },
);

__PACKAGE__->config( json_options => { relaxed => 1, pretty => 1, space_before => 1, space_after => 1 } );

sub extract : Local : ActionClass('REST')
{
}

sub extract_PUT : Local
{
    my ( $self, $c ) = @_;
    say STDERR Dumper( $c->req->{ parameters} );

    
    my $doc = $c->req->{ parameters }->{ doc };
    my $title = $c->req->{ parameters }->{ doc };
    my $description = $c->req->{ parameters }->{ doc };
    
    my @lines = split( /[\n\r]+/, $doc );

    my $lines = MediaWords::Crawler::Extractor::preprocess( \@lines );

    my $ret = MediaWords::DBI::Downloads::extract_preprocessed_lines_for_story( $lines, $title, $description );
    $self->status_ok( $c, entity => $ret );

}

sub extract_GET : Local
{
    my ( $self, $c, $id ) = @_;
    my $extract = $c->req->data;

}


1;
