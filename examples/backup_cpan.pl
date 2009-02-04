#!/home/acme/bin/perl
use strict;
use warnings;
use lib 'lib';
use Data::Stream::Bulk::Path::Class;
use Net::Amazon::S3;
use Perl6::Say;
use Path::Class;
use Set::Object;
use Term::ProgressBar::Simple;
use List::Util qw(sum);

#use Digest::MD5::File::Cached qw(file_md5_hex_cached);
use Digest::MD5::File qw(file_md5_hex);
use Cwd;
use Config;
use KiokuDB;
use MD5Cache;

my $kiokudb
    = KiokuDB->connect( "dbi:SQLite:dbname=md5cache.db", create => 1, );
my $scope = $kiokudb->new_scope;

my $s3 = Net::Amazon::S3->new(
    aws_access_key_id     => '0RJDWCWPV4E3660V6G82',
    aws_secret_access_key => 'ESHMa4/1PZn/r6/2xrfBNIU481jgKkqQ0DDiD5Yp',
    retry                 => 1,
);

my $client = Net::Amazon::S3::Client->new( s3 => $s3 );
my $bucket = $client->bucket( name => 'minicpan' );

my $root = '/home/acme/Public/minicpan/';

my $file_stream = Data::Stream::Bulk::Path::Class->new(
    dir        => Path::Class::Dir->new($root),
    only_files => 1,
);

my %files;

$kiokudb->txn_do( sub {
my $file_set = Set::Object->new();
until ( $file_stream->is_done ) {
    foreach my $filename ( $file_stream->items ) {
        my $key = $filename->relative($root)->stringify;

        my $md5cache = $kiokudb->lookup( $filename->stringify );
        unless ($md5cache) {
            $md5cache = MD5Cache->new(
                {   key     => $filename->stringify,
                    md5_hex => file_md5_hex($filename)
                }
            );
            $kiokudb->store( $filename->stringify => $md5cache );
        }

#say "$key " . $md5cache->md5_hex;
        $files{$key} = {
            filename => $filename,
            key      => $key,
            md5_hex  => $md5cache->md5_hex,
            size     => -s $filename,
        };
        $file_set->insert($key);
    }
}
});

die "did md5";

my %objects;
my $s3_set        = Set::Object->new();
my $object_stream = $bucket->list;
until ( $object_stream->is_done ) {
    foreach my $object ( $object_stream->items ) {
        my $key = $object->key;
        $objects{$key} = {
            filename => file( $root, $key )->stringify,
            key      => $key,
            md5_hex  => $object->etag,
            size     => $object->size,
        };

        say $object->key . ' ' . $object->size . ' ' . $object->etag;
        $s3_set->insert( $object->key );
    }
}

my @to_upload;
my @to_delete;

foreach my $key ( sort keys %files ) {
    my $file   = $files{$key};
    my $object = $objects{$key};
    if ($object) {
        if ( $file->{md5_hex} eq $object->{md5_hex} ) {

            say "$key same";
        } else {

            say "$key different";
            push @to_upload, $file;
        }
    } else {

        say "$key missing";
        push @to_upload, $file;
    }
}

foreach my $key ( sort keys %objects ) {
    my $object = $objects{$key};
    my $file   = $files{$key};
    if ($file) {
    } else {

        say "$key to delete";
        push @to_delete, $object;
    }
}

my $total_size = sum map { file( $_->{filename} )->stat->size } @to_upload;
$total_size += scalar(@to_delete);

my $progress = Term::ProgressBar::Simple->new($total_size);

foreach my $file (@to_upload) {
    my $key      = $file->{key};
    my $filename = $file->{filename};
    my $md5_hex  = $file->{md5_hex};
    my $size     = $file->{size};

    # say "put $key";
    $progress += $size;
    my $object = $bucket->object(
        key  => $key,
        etag => $md5_hex,
        size => $size
    );
    $object->put_filename($filename);
}

foreach my $object (@to_delete) {
    my $key      = $object->{key};
    my $filename = $object->{filename};
    my $object   = $bucket->object( key => $key );

    # say "delete $key";
    $object->delete;
    $progress++;
}

