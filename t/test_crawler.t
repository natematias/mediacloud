#!/usr/bin/env perl

use strict;
use warnings;
use Data::Dumper;
use Modern::Perl "2013";

#
# Basic sanity test of crawler functionality
#
# ---
#
# If you run t/test_crawler.t with the -d command it rewrites the files. E.g.:
#
#     ./script/run_with_carton.sh ./t/test_crawler.t  -d
#
# This changes the expected results so it's important to make sure that you're
# not masking bugs in the code. Also it's a good idea to manually examine the
# changes in t/data/top_500_weekly_words.pl and t/data/crawler_stories.pl
# before committing them.
#

BEGIN
{
    use FindBin;
    use lib "$FindBin::Bin/../lib";
    use lib $FindBin::Bin;
}

use Test::More;
use Test::Differences;
use Test::Deep;

require Test::NoWarnings;

use MediaWords::Crawler::Engine;
use MediaWords::DBI::DownloadTexts;
use MediaWords::DBI::MediaSets;
use MediaWords::DBI::Stories;
use MediaWords::Test::DB;
use MediaWords::Test::Data;
use MediaWords::Test::LocalServer;
use DBIx::Simple::MediaWords;
use MediaWords::StoryVectors;
use LWP::UserAgent;

use Data::Sorting qw( :basics :arrays :extras );
use Readonly;

#use feature 'unicode_strings';

# add a test media source and feed to the database
sub add_test_feed
{
    my ( $db, $url_to_crawl ) = @_;

    Readonly my $sw_data_start_date => '2008-02-03';
    Readonly my $sw_data_end_date   => '2014-02-27';

    my $test_medium = $db->query(
"insert into media (name, url, moderated, feeds_added, sw_data_start_date, sw_data_end_date) values (?, ?, ?, ?, ?, ?) returning *",
        '_ Crawler Test', $url_to_crawl, 0, 0, $sw_data_start_date, $sw_data_end_date
    )->hash;

    ok( MediaWords::StoryVectors::_medium_has_story_words_start_date( $test_medium ) );
    ok( MediaWords::StoryVectors::_medium_has_story_words_end_date( $test_medium ) );

    is( MediaWords::StoryVectors::_get_story_words_start_date_for_medium( $test_medium ), $sw_data_start_date );
    is( MediaWords::StoryVectors::_get_story_words_end_date_for_medium( $test_medium ),   $sw_data_end_date );

    my $syndicated_feed = $db->create(
        'feeds',
        {
            media_id => $test_medium->{ media_id },
            name     => '_ Crawler Test - Syndicated Feed',
            url      => "${ url_to_crawl }gv/test.rss"
        }
    );
    my $web_page_feed = $db->create(
        'feeds',
        {
            media_id  => $test_medium->{ media_id },
            name      => '_ Crawler Test - Web Page Feed',
            url       => "${ url_to_crawl }gv/gv_home.html",
            feed_type => 'web_page'
        }
    );

    MediaWords::DBI::MediaSets::create_for_medium( $db, $test_medium );

    ok( $syndicated_feed->{ feeds_id }, "test syndicated feed created" );
    ok( $web_page_feed->{ feeds_id },   "test web page feed created" );

    return $syndicated_feed;
}

Readonly my $crawler_timeout => 60;

# run the crawler for one minute, which should be enough time to gather all of the stories from the test feed
sub run_crawler
{

    my $crawler = MediaWords::Crawler::Engine->new();

    $crawler->processes( 1 );
    $crawler->throttle( 1 );
    $crawler->sleep_interval( 1 );
    $crawler->timeout( $crawler_timeout );
    $crawler->pending_check_interval( 1 );

    $| = 1;

    print "running crawler for one minute ...\n";
    $crawler->crawl();

    print "crawler exiting ...\n";
}

sub extract_downloads
{
    my ( $db ) = @_;

    print "extracting downloads ...\n";

    my $downloads = $db->query( "select * from downloads where type = 'content' order by stories_id, downloads_id" )->hashes;

    for my $download ( @{ $downloads } )
    {
        MediaWords::DBI::Downloads::process_download_for_extractor( $db, $download, 1 );
    }
}

sub update_download_texts
{
    my ( $db ) = @_;

    my $download_texts = $db->query( "select * from download_texts" )->hashes;

    for my $download_text ( @{ $download_texts } )
    {
        MediaWords::DBI::DownloadTexts::update_text( $db, $download_text );
    }
}

# run extractor, tagger, and vector on all stories
sub process_stories
{
    my ( $db ) = @_;

    print "processing stories ...\n";

    my $stories = $db->query( "select * from stories" )->hashes;

    for my $story ( @{ $stories } )
    {
        print "adding default tags ...\n";
        MediaWords::DBI::Stories::add_default_tags( $db, $story );
    }

    print "processing stories done.\n";
}

# get stories from database, including content, text, tags, sentences, sentence_words, and story_sentence_words
sub get_expanded_stories
{
    my ( $db ) = @_;

    my $stories = $db->query( "select s.*, f.feed_type from stories s, feeds_stories_map fsm, feeds f " .
          "  where s.stories_id = fsm.stories_id and fsm.feeds_id = f.feeds_id" )->hashes;

    for my $story ( @{ $stories } )
    {
        $story->{ content } = ${ MediaWords::DBI::Stories::fetch_content( $db, $story ) };
        $story->{ extracted_text } = MediaWords::DBI::Stories::get_text( $db, $story );
        $story->{ tags } = MediaWords::DBI::Stories::get_db_module_tags( $db, $story, 'NYTTopics' );

        $story->{ story_sentence_words } =
          $db->query( "select * from story_sentence_words where stories_id = ?", $story->{ stories_id } )->hashes;

        $story->{ story_sentences } =
          $db->query( "select * from story_sentences where stories_id = ? order by stories_id, sentence_number ",
            $story->{ stories_id } )->hashes;

    }

    return $stories;
}

sub _purge_story_sentences_id_field
{
    my ( $sentences ) = @_;

    for my $sentence ( @$sentences )
    {

        #die Dumper ($sentence ) unless $sentence->{story_sentences_id };

        #die Dumper ($sentence);

        $sentence->{ story_sentences_id } = '';
        delete $sentence->{ story_sentences_id };
    }
}

# replace all stories_id fields with the normalized url of the corresponding story
# within the stories data structure
sub replace_stories_ids_with_urls
{
    my ( $stories ) = @_;

    my $story_urls = {};
    for my $story ( @{ $stories } )
    {
        my $url = $story->{ url };
        $url =~ s~https?://[^/]*~~;
        $story_urls->{ $story->{ stories_id } } = $url;
    }

    my $stack = [ @{ $stories } ];
    while ( @{ $stack } )
    {
        my $o = pop( @{ $stack } );

        if ( ref( $o ) eq 'HASH' )
        {
            if ( $o->{ stories_id } )
            {
                $o->{ stories_id } = $story_urls->{ $o->{ stories_id } };
            }

            push( @{ $stack }, values( %{ $o } ) );
        }
        elsif ( ref( $o ) eq 'ARRAY' )
        {
            push( @{ $stack }, @{ $o } );
        }
    }
}

# test various results of the crawler
sub test_stories
{
    my ( $db ) = @_;

    my $download_errors = $db->query( "select * from downloads where state = 'error'" )->hashes;
    is( scalar( @{ $download_errors } ), 0, "download errors" );
    die( "errors: " . Dumper( $download_errors ) ) if ( @{ $download_errors } );

    my $stories = get_expanded_stories( $db );

    is( @{ $stories }, 16, "story count" );

    my $test_stories = MediaWords::Test::Data::fetch_test_data( 'crawler_stories' );

    # replace stories_id with urls so that the order of stories
    # doesn't matter
    replace_stories_ids_with_urls( $stories );
    replace_stories_ids_with_urls( $test_stories );

    my $test_story_hash;
    map { $test_story_hash->{ $_->{ title } } = $_ } @{ $test_stories };

    for my $story ( @{ $stories } )
    {
        my $test_story = $test_story_hash->{ $story->{ title } };
        if ( ok( $test_story, "story match: " . $story->{ title } ) )
        {

            #$story->{ extracted_text } =~ s/\n//g;
            #$test_story->{ extracted_text } =~ s/\n//g;

            my $fields = [ qw(description extracted_text) ];

            # can't test web_page story dates against historical data b/c they are supposed to have
            # the current date
            push( @{ $fields }, qw(publish_date guid) ) unless ( $story->{ feed_type } eq 'web_page' );

            for my $field ( @{ $fields } )
            {
                oldstyle_diff;

              TODO:
                {
                    my $fake_var;    #silence warnings
                     #eq_or_diff( $story->{ $field }, encode_utf8($test_story->{ $field }), "story $field match" , {context => 0});
                    is( $story->{ $field }, $test_story->{ $field }, "story $field match" );
                }
            }

            unless ( eq_or_diff( $story->{ content }, $test_story->{ content }, "story content matches" ) )
            {

                #print STDERR "Expected content: " . Dumper( $test_story->{ content } );
                #print STDERR "Got content: " . Dumper( $story->{ content } );
            }

            is( scalar( @{ $story->{ tags } } ), scalar( @{ $test_story->{ tags } } ), "story tags count" );

            unless (
                is(
                    scalar( @{ $story->{ story_sentences } } ),
                    scalar( @{ $test_story->{ story_sentences } } ),
                    "story sentence count" . $story->{ stories_id }
                )
              )
            {
                print STDERR "Expected sentence count: " . scalar( @{ $test_story->{ story_sentences } } ) . "\n";
                print STDERR "Expected sentences: " . Dumper( $test_story->{ story_sentences } );
                print STDERR "Got sentence count: " . scalar( @{ $story->{ story_sentences } } ) . "\n";
                print STDERR "Got sentences: " . Dumper( $story->{ story_sentences } );
            }

            _purge_story_sentences_id_field( $story->{ story_sentences } );
            _purge_story_sentences_id_field( $test_story->{ story_sentences } );

            # as above, don't compare dates for web_page stories
            if ( $story->{ feed_type } eq 'web_page' )
            {
                map { delete( $_->{ publish_date } ) }
                  ( @{ $story->{ story_sentences } }, @{ $test_story->{ story_sentences } } );
            }

            # don't compare timestamp-dependent "db_row_last_updated" fields
            map { delete( $_->{ db_row_last_updated } ) }
              ( @{ $story->{ story_sentences } }, @{ $test_story->{ story_sentences } } );

            cmp_deeply(
                $story->{ story_sentences },
                $test_story->{ story_sentences },
                "story sentences " . $story->{ stories_id }
            );

          TODO:
            {
                my $fake_var;    #silence warnings

                my $test_story_sentence_words_count = scalar( @{ $test_story->{ story_sentence_words } } );
                my $story_sentence_words_count      = scalar( @{ $story->{ story_sentence_words } } );

                unless (
                    is(
                        $story_sentence_words_count, $test_story_sentence_words_count,
                        "story words count for " . $story->{ stories_id }
                    )
                  )
                {
                    print STDERR "Expected words: " . Dumper( $test_story->{ story_sentence_words } );
                    print STDERR "Got words: " . Dumper( $story->{ story_sentence_words } );
                }
            }
        }

        delete( $test_story_hash->{ $story->{ title } } );
    }

}

sub generate_aggregate_words
{
    my ( $db ) = @_;

    my ( $start_date ) = $db->query( "select date_trunc( 'day', min(publish_date) ) from stories" )->flat;

    #( $start_date ) = $db->query( "select date_trunc( 'day', min(publish_date)  - interval '1 week' ) from stories" )->flat;
    my ( $end_date ) = $db->query( "select date_trunc( 'day', max(publish_date) ) from stories" )->flat;

    #( $end_date )   = $db->query( "select date_trunc( 'day', max(publish_date) + interval '1 month' ) from stories" )->flat;

    my $dashboard =
      $db->create( 'dashboards', { name => 'test_dashboard', start_date => $start_date, end_date => $end_date } );

    my $dashboard_topic = $db->create(
        'dashboard_topics',
        {
            dashboards_id => $dashboard->{ dashboards_id },
            name          => 'obama_topic',
            query         => 'obama',
            language      => 'en',
            start_date    => $start_date,
            end_date      => $end_date
        }
    );

    MediaWords::StoryVectors::update_aggregate_words( $db, $start_date, $end_date );
}

sub _process_top_500_weekly_words_for_testing
{
    my ( $hashes ) = @_;

    foreach my $hash ( @{ $hashes } )
    {
        delete( $hash->{ top_500_weekly_words_id } );
    }
}

# simple test to verify that top 500 weekly words has at least 500 words
sub sanity_test_top_500_weekly_words
{
    my ( $words ) = @_;

    ok( scalar( @{ $words } ) >= 500, "top 500 weekly words has at least 500 words" );
}

sub dump_top_500_weekly_words
{
    my ( $db ) = @_;

    my $top_500_weekly_words = $db->query( 'SELECT * FROM top_500_weekly_words order by publish_week, stem, term', )->hashes;
    _process_top_500_weekly_words_for_testing( $top_500_weekly_words );

    MediaWords::Test::Data::store_test_data( 'top_500_weekly_words', $top_500_weekly_words );

    sanity_test_top_500_weekly_words( $top_500_weekly_words );

    return;
}

sub sort_top_500_weekly_words
{
    my ( $array ) = @_;

    #ensure that the order is deterministic
    #first sort on the important fields then sort on everything just to be sure...
    my @keys = qw (publish_week stem dashboard_topics_id term );

    my @hash_fields = sort keys %{ $array->[ 0 ] };

    return [ sorted_array( @$array, @keys, @hash_fields ) ];
}

sub test_top_500_weekly_words
{
    my ( $db ) = @_;

    my $top_500_weekly_words_actual =
      $db->query( 'SELECT * FROM top_500_weekly_words order by publish_week, stem, term' )->hashes;
    _process_top_500_weekly_words_for_testing( $top_500_weekly_words_actual );

    my $top_500_weekly_words_expected = MediaWords::Test::Data::fetch_test_data( 'top_500_weekly_words' );

    is(
        scalar( @{ $top_500_weekly_words_actual } ),
        scalar( @{ $top_500_weekly_words_expected } ),
        'Top 500 weekly words table row count'
    );

    $top_500_weekly_words_actual   = sort_top_500_weekly_words( $top_500_weekly_words_actual );
    $top_500_weekly_words_expected = sort_top_500_weekly_words( $top_500_weekly_words_expected );

    my $i;

    for ( $i = 0 ; $i < scalar( @{ $top_500_weekly_words_actual } ) ; $i++ )
    {
        my $actual_row   = $top_500_weekly_words_actual->[ $i ];
        my $expected_row = $top_500_weekly_words_expected->[ $i ];

        #undef($actual_row->{term});
        #undef($expected_row->{term});
        cmp_deeply( $actual_row, $expected_row, "top_500_weekly_words row $i comparison" );
        my @keys = sort ( keys %{ $expected_row } );

        @keys = grep { defined( $expected_row->{ $_ } ) } @keys;

        my $actual_row_string   = join ',', ( @{ $actual_row }{ @keys } );
        my $expected_row_string = join ',', ( @{ $expected_row }{ @keys } );

        is( $actual_row_string, $expected_row_string, "top_500_weekly_words row $i string comparison:" . join ",", @keys );
    }
}

# simple test to verify that each story has at least 10 words
sub sanity_test_stories
{
    my ( $stories ) = @_;

    for my $story ( @{ $stories } )
    {
        ok( scalar( @{ $story->{ story_sentence_words } } ) >= 10, "story '$story->{ url }' has at least 10 words" );
    }
}

# store the stories as test data to compare against in subsequent runs
sub dump_stories
{
    my ( $db ) = @_;

    my $stories = get_expanded_stories( $db );

    MediaWords::Test::Data::store_test_data( 'crawler_stories', $stories );

    sanity_test_stories( $stories );
}

sub kill_local_server
{
    my ( $server_url ) = @_;

    my $ua = LWP::UserAgent->new;

    $ua->timeout( 10 );

    my $kill_url = "$server_url" . "kill_server";
    print STDERR "Getting $kill_url\n";
    my $resp = $ua->get( $kill_url ) || die;
    print STDERR "got url";
    die $resp->status_line unless $resp->is_success;
}

sub get_crawler_data_directory
{
    my $crawler_data_location;

    {
        use FindBin;

        my $bin = $FindBin::Bin;
        say "Bin = '$bin' ";
        $crawler_data_location = "$FindBin::Bin/data/crawler";
    }

    print "crawler data '$crawler_data_location'\n";

    return $crawler_data_location;
}

sub main
{
    my ( $dump ) = @ARGV;

    MediaWords::Test::DB::test_on_test_database(
        sub {
            use Encode;
            my ( $db ) = @_;

            # Errors might want to print out UTF-8 characters
            binmode( STDOUT, ":utf8" );
            binmode( STDERR, ":utf8" );

            my $crawler_data_location = get_crawler_data_directory();

            my $url_to_crawl = MediaWords::Test::LocalServer::start_server( $crawler_data_location );

            add_test_feed( $db, $url_to_crawl );

            run_crawler();

            extract_downloads( $db );

            process_stories( $db );

            if ( defined( $dump ) && ( $dump eq '-d' ) )
            {
                dump_stories( $db );
            }

            test_stories( $db );

            generate_aggregate_words( $db );

            ## Temporary hack to get the test suite working again.
            $db->query( "DELETE from top_500_weekly_words where publish_week > now() - interval '1 week' " );

            if ( defined( $dump ) && ( $dump eq '-d' ) )
            {
                dump_top_500_weekly_words( $db );
            }

            test_top_500_weekly_words( $db );

            print "Killing server\n";
            kill_local_server( $url_to_crawl );

            Test::NoWarnings::had_no_warnings();
            done_testing();
        }
    );

}

main();

