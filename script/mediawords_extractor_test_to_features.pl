#!/usr/bin/env perl

# test MediaWords::Crawler::Extractor against manually extracted downloads

use strict;
use warnings;

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../lib";
}

use MediaWords::Crawler::Extractor;
use Getopt::Long;
use HTML::Strip;
use DBIx::Simple::MediaWords;
use MediaWords::DB;
use Modern::Perl "2012";
use MediaWords::CommonLibs;
use MediaWords::Util::HTML;

use MediaWords::DBI::Downloads;
use Readonly;
use List::Util qw(first max maxstr min minstr reduce shuffle sum);
use List::MoreUtils qw( uniq distinct :all );
use List::Compare::Functional qw (get_unique get_complement get_union_ref );
use Lingua::EN::Sentence::MediaWords;
use Text::Trim;

use Data::Dumper;
use MediaWords::Util::HTML;
use MediaWords::Util::ExtractorTest;
use Data::Compare;
use Storable;
use 5.14.2;

my $_re_generate_cache = 0;
my $_test_sentences    = 0;

my $_download_data_load_file;
my $_download_data_store_file;
my $_dont_store_preprocessed_lines;
my $_dump_training_data_csv;

sub get_word_counts
{
    my ( $downloads ) = @_;

    my $word_counts = {};

    foreach my $download ( @{ $downloads } )
    {
        my $line_count = scalar( @{ $download->{ line_info } } );

        die unless scalar( @{ $download->{ line_info } } ) == scalar( @{ $download->{ preprocessed_lines } } );

        my $line_infos         = $download->{ line_info };
        my $preprocessed_lines = $download->{ preprocessed_lines };

        my $ea = each_arrayref( $line_infos, $preprocessed_lines );

        while ( my ( $line_info, $preprocessed_line ) = $ea->() )
        {
            if ( $line_info->{ auto_excluded } )
            {
                next if $preprocessed_line eq '';
                next if $preprocessed_line eq ' ';

                #say Dumper($preprocessed_line );

                my @words = @{ MediaWords::Crawler::AnalyzeLines::words_on_line( $preprocessed_line ) };

                foreach my $word ( @words )
                {
                    $word_counts->{ $word } //= 0;
                    $word_counts->{ $word }++;
                }
            }
        }
    }

    return $word_counts;

}

sub get_word_counts_by_class
{
    my ( $downloads ) = @_;

    my $word_counts = {};

    foreach my $download ( @{ $downloads } )
    {
        my $line_count = scalar( @{ $download->{ line_info } } );

        die unless scalar( @{ $download->{ line_info } } ) == scalar( @{ $download->{ preprocessed_lines } } );

        my $line_infos         = $download->{ line_info };
        my $preprocessed_lines = $download->{ preprocessed_lines };

        my $ea = each_arrayref( $line_infos, $preprocessed_lines );

        while ( my ( $line_info, $preprocessed_line ) = $ea->() )
        {
            if ( $line_info->{ auto_excluded } )
            {
                next if $preprocessed_line eq '';
                next if $preprocessed_line eq ' ';

                #say Dumper($preprocessed_line );

                my @words = @{ MediaWords::Crawler::AnalyzeLines::words_on_line( $preprocessed_line ) };

                foreach my $word ( @words )
                {
                    $word_counts->{ $line_info->{ class } }->{ $word } //= 0;
                    $word_counts->{ $line_info->{ class } }->{ $word }++;
                }
            }
        }
    }

    return $word_counts;
}

sub add_distance_from_previous_line
{
    my ( $downloads ) = @_;

    foreach my $download ( @{ $downloads } )
    {

        my $last_in_story_line;

        my $line_num = 0;

        foreach my $line ( @{ $download->{ line_info } } )
        {

            my $line_number = $line->{ line_number };

            if ( defined( $last_in_story_line ) )
            {
                $line->{ distance_from_previous_in_story_line } = $line_number - $last_in_story_line;
            }

            $line->{ class } = $download->{ line_should_be_in_story }->{ $line_number } // 'excluded';

            if ( $line->{ class } ne 'excluded' )
            {
                $last_in_story_line = $line_number;
            }
        }

    }

    return;

}

sub sort_pmi
{
    my ( $pmi ) = @_;

    my $ret = {};

    foreach my $class ( keys %{ $pmi } )
    {
        my $class_pmi = $pmi->{ $class };

        my @features = keys { %$class_pmi };

        my $sorted_features = [ sort { $class_pmi->{ $b } <=> $class_pmi->{ $a } } @features ];

        $ret->{ $class } = $sorted_features;
    }

    return $ret;
}

sub get_top_words
{
    my ( $downloads ) = @_;

    my $word_counts = get_word_counts( $downloads );

    my $word_counts_by_class = get_word_counts_by_class( $downloads );

    #say Dumper( $word_counts_by_class );

    use Algorithm::FeatureSelection;

    my $fs = Algorithm::FeatureSelection->new();

    my $ig = $fs->information_gain( $word_counts_by_class );

    my $igr = $fs->information_gain_ratio( $word_counts_by_class );

    #   say Dumper( $igr );

    my $pmi = $fs->pairwise_mutual_information( $word_counts_by_class );

    my $pmi_sorted = sort_pmi( $pmi );

    my $high_pmi_words = [];

    foreach my $class ( keys %$pmi_sorted )
    {
        my $list = $pmi_sorted->{ $class };

        my @top = @{ $list }[ 0 ... min( 10, scalar( @{ $list } ) - 1 ) ];

        push $high_pmi_words, @top;

        #say Dumper( $high_pmi_words );
    }

    my @words = keys %{ $word_counts };

    @words = sort { $word_counts->{ $b } <=> $word_counts->{ $a } } @words;

    my %top_words = map { $_ => 1 } @words[ 0 .. 1000 ];

    foreach my $high_pmi_word ( @{ $high_pmi_words } )
    {
        die Dumper( $high_pmi_words ) unless defined( $high_pmi_word );

        if ( defined( $top_words{ $high_pmi_word } ) )
        {

            #say "$high_pmi_word is in top words";
        }
        else
        {

            #say "$high_pmi_word is NOT in top words";
        }

        # $top_words{ $high_pmi_word } = 1;
    }

    return \%top_words;
}

sub main
{
    my $file;

    GetOptions(
        'file|f=s' => \$file,

        # 'download_data_load_file=s'     => \$_download_data_load_file,
        # 'download_data_store_file=s'    => \$_download_data_store_file,
        # 'dont_store_preprocessed_lines' => \$_dont_store_preprocessed_lines,
        # 'dump_training_data_csv'        => \$_dump_training_data_csv,
    ) or die;

    die unless $file;

    my $downloads = retrieve( $file );

    #say Dumper( $downloads );

    say STDERR "retrieved file";

    add_distance_from_previous_line( $downloads );

    # say STDERR "About to call add_additional_features";

    # add_additional_features( $downloads );

    # say STDERR "Returned from call to add_additional_features";

    my $top_words = get_top_words( $downloads );

    foreach my $download ( @{ $downloads } )
    {
        my $ea = each_arrayref( $download->{ line_info }, $download->{ preprocessed_lines } );

        #TODO DRY out this code
        my $previous_states = [ qw ( prestart start ) ];
        while ( my ( $line_info, $line_text ) = $ea->() )
        {

            my $current_state = $line_info->{ class };

            if ( $line_info->{ auto_excluded } == 1 )
            {
                $current_state = 'auto_excluded';
            }

            my $prior_state_string = join '_', @$previous_states;
            $line_info->{ "priors_$prior_state_string" } = 1;

            if ( $previous_states->[ 1 ] eq 'auto_excluded' )
            {
                $line_info->{ previous_line_auto_excluded } = 1;
            }

            shift $previous_states;

            push $previous_states, $current_state;

            next if $line_info->{ auto_excluded } == 1;

            MediaWords::Crawler::AnalyzeLines::add_additional_features( $line_info, $line_text );

            my $feature_string =
              MediaWords::Crawler::AnalyzeLines::get_feature_string_from_line_info( $line_info, $line_text, $top_words );
            say $feature_string;
        }
    }
}

main();