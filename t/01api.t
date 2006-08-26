#!/usr/bin/perl -w
use warnings;
use strict;
use Test::More;

         unless( $ENV{'AMAZON_S3_EXPENSIVE_TESTS'} ){
             plan skip_all => 'Testing this module for real costs money.';
         }
         else {
             plan tests => 31;
         }



use_ok ('Net::Amazon::S3');

# this synopsis is presented as a test file

use vars qw/$OWNER_ID $OWNER_DISPLAYNAME/;

my $aws_access_key_id     = $ENV{'AWS_ACCESS_KEY_ID'};
my $aws_secret_access_key = $ENV{'AWS_ACCESS_KEY_SECRET'};

my $s3 = Net::Amazon::S3->new(
    {   aws_access_key_id     => $aws_access_key_id,
        aws_secret_access_key => $aws_secret_access_key
    }
);

# list all buckets that i own
my $response = $s3->buckets;

TODO: {
    local $TODO = "These tests only work if you're leon";
    $OWNER_ID          = $response->{owner_id};
    $OWNER_DISPLAYNAME = $response->{owner_displayname};

    like( $response->{owner_id},          qr/^46a801915a1711f/ );
    is( $response->{owner_displayname}, '_acme_' );
    is_deeply( $response->{buckets}, [] );
}

# create a bucket
my $bucketname = $aws_access_key_id . '-net-amazon-s3-test';
my $bucket_obj = $s3->add_bucket( { bucket => $bucketname } )
    or die $s3->err . ": " . $s3->errstr;
is( ref $bucket_obj, "Net::Amazon::S3::Bucket" );

# another way to get a bucket object (does no network I/O,
# assumes it already exists).  Read Net::Amazon::S3::Bucket.
$bucket_obj = $s3->bucket($bucketname);
is( ref $bucket_obj, "Net::Amazon::S3::Bucket" );

# fetch contents of the bucket
# note prefix, marker, max_keys options can be passed in
$response = $bucket_obj->list
    or die $s3->err . ": " . $s3->errstr;
is( $response->{bucket},       $bucketname );
is( $response->{prefix},       '' );
is( $response->{marker},       '' );
is( $response->{max_keys},     1_000 );
is( $response->{is_truncated}, 0 );
is_deeply( $response->{keys}, [] );

# store a key with a content-type and some optional metadata
my $keyname = 'testing.txt';
my $value   = 'T';
$bucket_obj->add_key(
    $keyname, $value,
    {   content_type        => 'text/plain',
        'x-amz-meta-colour' => 'orange',
    }
);

# list keys in the bucket
$response = $bucket_obj->list
    or die $s3->err . ": " . $s3->errstr;
is( $response->{bucket},       $bucketname );
is( $response->{prefix},       '' );
is( $response->{marker},       '' );
is( $response->{max_keys},     1_000 );
is( $response->{is_truncated}, 0 );
my @keys = @{ $response->{keys} };
is( @keys, 1 );
my $key = $keys[0];
is( $key->{key}, $keyname );

# the etag is the MD5 of the value
is( $key->{etag}, 'b9ece18c950afbfa6b0fdbfa4ff731d3' );
is( $key->{size}, 1 );

is( $key->{owner_id},          $OWNER_ID );
is( $key->{owner_displayname}, $OWNER_DISPLAYNAME );

# You can't delete a bucket with things in it
ok( !$bucket_obj->delete_bucket() );

$bucket_obj->delete_key($keyname);

# fetch contents of the bucket
# note prefix, marker, max_keys options can be passed in
$response = $bucket_obj->list
    or die $s3->err . ": " . $s3->errstr;
is( $response->{bucket},       $bucketname );
is( $response->{prefix},       '' );
is( $response->{marker},       '' );
is( $response->{max_keys},     1_000 );
is( $response->{is_truncated}, 0 );
is_deeply( $response->{keys}, [] );

ok( $bucket_obj->delete_bucket() );

# see more docs in Net::Amazon::S3::Bucket
