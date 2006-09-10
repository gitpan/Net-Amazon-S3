package Net::Amazon::S3;
use strict;
use warnings;

=head1 NAME

Net::Amazon::S3 - Use the Amazon S3 - Simple Storage Service

=head1 SYNOPSIS

  #!/usr/bin/perl
  use warnings;
  use strict;
  use Test::More qw/no_plan/;
  
  # this synopsis is presented as a test file

  use Net::Amazon::S3;
  
  
  use vars qw/$OWNER_ID $OWNER_DISPLAYNAME/;
  
  my $aws_access_key_id     = "Fill me in!";
  my $aws_secret_access_key = "Fill me in too!";
  
  my $s3 = Net::Amazon::S3->new(
      {   aws_access_key_id     => $aws_access_key_id,
          aws_secret_access_key => $aws_secret_access_key
      }
  );
  
  # you can also pass a timeout in seconds
  
  # list all buckets that i own
  my $response = $s3->buckets;
  
  TODO: {
      local $TODO = "These tests only work if you're leon";
      $OWNER_ID          = $response->{owner_id};
      $OWNER_DISPLAYNAME = $response->{owner_displayname};
  
      is( $response->{owner_id},          '46a801915a1711f...' );
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
  
=head1 DESCRIPTION

This module provides a Perlish interface to Amazon S3. From the
developer blurb: "Amazon S3 is storage for the Internet. It is
designed to make web-scale computing easier for developers. Amazon S3
provides a simple web services interface that can be used to store and
retrieve any amount of data, at any time, from anywhere on the web. It
gives any developer access to the same highly scalable, reliable,
fast, inexpensive data storage infrastructure that Amazon uses to run
its own global network of web sites. The service aims to maximize
benefits of scale and to pass those benefits on to developers".

To find out more about S3, please visit: http://s3.amazonaws.com/

To use this module you will need to sign up to Amazon Web Services and
provide an "Access Key ID" and " Secret Access Key". If you use this
module, you will incurr costs as specified by Amazon. Please check the
costs. If you use this module with your Access Key ID and Secret
Access Key you must be responsible for these costs.

I highly recommend reading all about S3, but in a nutshell data is
stored in values. Values are referenced by keys, and keys are stored
in buckets. Bucket names are global.

Some features, such as ACLs, are not yet implemented. Patches welcome!

=cut

use Carp;
use Digest::HMAC_SHA1;
use HTTP::Date;
use MIME::Base64 qw(encode_base64);
use Net::Amazon::S3::Bucket;
use LWP::UserAgent;
use URI::Escape;
use XML::LibXML;
use XML::LibXML::XPathContext;

use base qw(Class::Accessor::Fast);
__PACKAGE__->mk_accessors(
    qw(libxml aws_access_key_id aws_secret_access_key secure ua err errstr timeout)
);
our $VERSION = '0.34';

my $AMAZON_HEADER_PREFIX = 'x-amz-';
my $METADATA_PREFIX      = 'x-amz-meta-';
my $KEEP_ALIVE_CACHESIZE = 10;

=head1 METHODS

=head2 new 

Create a new S3 client object. Takes some arguments:

=over

=item aws_access_key_id 

Use your Access Key ID as the value of the AWSAccessKeyId parameter
in requests you send to Amazon Web Services (when required). Your
Access Key ID identifies you as the party responsible for the
request.

=item aws_secret_access_key 

Since your Access Key ID is not encrypted in requests to AWS, it
could be discovered and used by anyone. Services that are not free
require you to provide additional information, a request signature,
to verify that a request containing your unique Access Key ID could
only have come from you.

DO NOT INCLUDE THIS IN SCRIPTS OR APPLICATIONS YOU DISTRIBUTE. YOU'LL BE SORRY

=item secure 

Set this to C<1> if you want to use SSL-encrypted connections when talking
to S3. Defaults to C<0>.

=item timeout

How many seconds should your script wait before bailing on a request to S3? Defaults
to 30.

=back

=cut

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);

    die "No aws_access_key_id"     unless $self->aws_access_key_id;
    die "No aws_secret_access_key" unless $self->aws_secret_access_key;

    $self->secure(0)   if not defined $self->secure;
    $self->timeout(30) if not defined $self->timeout;

    my $ua = LWP::UserAgent->new( keep_alive => $KEEP_ALIVE_CACHESIZE );
    $ua->timeout( $self->timeout );
    $self->ua($ua);
    $self->libxml( XML::LibXML->new );
    return $self;
}

=head2 buckets

Returns undef on error, else hashref of results

=cut

sub buckets {
    my $self = shift;
    my $xpc  = $self->_send_request( 'GET', '', {} );

    return undef unless $xpc && !$self->_remember_errors($xpc);

    my $owner_id          = $xpc->findvalue("//s3:Owner/s3:ID");
    my $owner_displayname = $xpc->findvalue("//s3:Owner/s3:DisplayName");

    my @buckets;
    foreach my $node ( $xpc->findnodes(".//s3:Bucket") ) {
        push @buckets,
            Net::Amazon::S3::Bucket->new(
            {   bucket        => $xpc->findvalue( ".//s3:Name", $node ),
                creation_date =>
                    $xpc->findvalue( ".//s3:CreationDate", $node ),
                account => $self,
            }
            );

    }
    return {
        owner_id          => $owner_id,
        owner_displayname => $owner_displayname,
        buckets           => \@buckets,
    };
}

=head2 add_bucket 

Takes a hashref:

=over

=item bucket

The name of the bucket you want to add

=back

Returns 0 on failure, Net::Amazon::S3::Bucket object on success

=cut

sub add_bucket {
    my ( $self, $conf ) = @_;
    my $bucket = $conf->{bucket};
    croak 'must specify bucket' unless $bucket;
    return 0 unless $self->_send_request_expect_nothing( 'PUT', $bucket, {} );
    return $self->bucket($bucket);
}

=head2 bucket BUCKET

Takes a scalar argument, the name of the bucket you're creating

Returns an (unverified) bucket object from an account. Does no network access.

=cut

sub bucket {
    my ( $self, $bucketname ) = @_;
    return Net::Amazon::S3::Bucket->new(
        { bucket => $bucketname, account => $self } );
}

=head2 delete_bucket

Takes either a L<Net::Amazon::S3::Bucket> object or a hashref containing 

=over

=item bucket

The name of the bucket to remove

=back

Returns false (and fails) if the bucket isn't empty.

Returns true if the bucket is successfully deleted.

=cut

sub delete_bucket {
    my ( $self, $conf ) = @_;
    my $bucket;
    if ( eval { $conf->isa("Net::S3::Amazon::Bucket"); } ) {
        $bucket = $conf->bucket;
    } else {
        $bucket = $conf->{bucket};
    }
    croak 'must specify bucket' unless $bucket;
    return $self->_send_request_expect_nothing( 'DELETE', $bucket, {} );
}

=head2 list_bucket

List all keys in this bucket.

Takes a hashref of arguments:

MANDATORY

=over

=item bucket

The name of the bucket you want to list keys on

=back

OPTIONAL

=over

=item prefix

Restricts the response to only contain results that begin with the
specified prefix. If you omit this optional argument, the value of
prefix for your query will be the empty string. In other words, the
results will be not be restricted by prefix.

=item delimiter

If this optional, Unicode string parameter is included with your
request, then keys that contain the same string between the prefix
and the first occurrence of the delimiter will be rolled up into a
single result element in the CommonPrefixes collection. These
rolled-up keys are not returned elsewhere in the response.  For
example, with prefix="USA/" and delimiter="/", the matching keys
"USA/Oregon/Salem" and "USA/Oregon/Portland" would be summarized
in the response as a single "USA/Oregon" element in the CommonPrefixes
collection. If an otherwise matching key does not contain the
delimiter after the prefix, it appears in the Contents collection.

Each element in the CommonPrefixes collection counts as one against
the MaxKeys limit. The rolled-up keys represented by each CommonPrefixes
element do not.  If the Delimiter parameter is not present in your
request, keys in the result set will not be rolled-up and neither
the CommonPrefixes collection nor the NextMarker element will be
present in the response.

NOTE (TODO): CommonPrefixes isn't currently supported by Net::Amazon::S3. 
Patches welcome



=item max-keys 

This optional argument limits the number of results returned in
response to your query. Amazon S3 will return no more than this
number of results, but possibly less. Even if max-keys is not
specified, Amazon S3 will limit the number of results in the response.
Check the IsTruncated flag to see if your results are incomplete.
If so, use the Marker parameter to request the next page of results.
For the purpose of counting max-keys, a 'result' is either a key
in the 'Contents' collection, or a delimited prefix in the
'CommonPrefixes' collection. So for delimiter requests, max-keys
limits the total number of list results, not just the number of
keys.

=item marker

This optional parameter enables pagination of large result sets.
C<marker> specifies where in the result set to resume listing. It
restricts the response to only contain results that occur alphabetically
after the value of marker. To retrieve the next page of results,
use the last key from the current page of results as the marker in
your next request.

See also C<next_marker>, below. 

If C<marker> is omitted,the first page of results is returned. 

=back


Returns undef on error and a hashref of data on success:

The hashref looks like this:

  {
        bucket       => $bucket_name,
        prefix       => $bucket_prefix, 
        marker       => $bucket_marker, 
        next_marker  => $bucket_next_available_marker,
        max_keys     => $bucket_max_keys,
        is_truncated => $bucket_is_truncated_boolean
        keys          => [$key1,$key2,...]
   }

Explanation of bits of that:

=over


=item is_truncated

B flag that indicates whether or not all results of your query were
returned in this response. If your results were truncated, you can
make a follow-up paginated request using the Marker parameter to
retrieve the rest of the results.


=item next_marker 

A convenience element, useful when paginating with delimiters. The
value of C<next_marker>, if present, is the largest (alphabetically)
of all key names and all CommonPrefixes prefixes in the response.
If the C<is_truncated> flag is set, request the next page of results
by setting C<marker> to the value of C<next_marker>. This element
is only present in the response if the C<delimiter> parameter was
sent with the request.

=back



Each key is a hashref that looks like this:

     {
        key           => $key,
        last_modified => $last_mod_date,
        etag          => $etag, # An MD5 sum of the stored content.
        size          => $size, # Bytes
        storage_class => $storage_class # Doc?
        owner_id      => $owner_id,
        owner_displayname => $owner_name
    }

=cut

sub list_bucket {
    my ( $self, $conf ) = @_;
    my $bucket = delete $conf->{bucket};
    croak 'must specify bucket' unless $bucket;
    $conf ||= {};

    my $path = $bucket;
    if (%$conf) {
        $path .= "?"
            . join( '&',
            map { $_."=" . $self->_urlencode( $conf->{$_} ) } keys %$conf );
    }

    my $xpc = $self->_send_request( 'GET', $path, {} );
    return undef unless $xpc && !$self->_remember_errors($xpc);

    my $return = {
        bucket       => $xpc->findvalue("//s3:ListBucketResult/s3:Name"),
        prefix       => $xpc->findvalue("//s3:ListBucketResult/s3:Prefix"),
        marker       => $xpc->findvalue("//s3:ListBucketResult/s3:Marker"),
        next_marker  => $xpc->findvalue("//s3:ListBucketResult/s3:NextMarker"),
        max_keys     => $xpc->findvalue("//s3:ListBucketResult/s3:MaxKeys"),
        is_truncated => (
            scalar $xpc->findvalue("//s3:ListBucketResult/s3:IsTruncated") eq
                'true'
            ? 1
            : 0
        ),
    };

    my @keys;
    foreach my $node ( $xpc->findnodes(".//s3:Contents") ) {
        my $etag = $xpc->findvalue( ".//s3:ETag", $node );
        $etag =~ s/^"//;
        $etag =~ s/"$//;

        push @keys,
            {
            key           => $xpc->findvalue( ".//s3:Key",          $node ),
            last_modified => $xpc->findvalue( ".//s3:LastModified", $node ),
            etag          => $etag,
            size          => $xpc->findvalue( ".//s3:Size",         $node ),
            storage_class => $xpc->findvalue( ".//s3:StorageClass", $node ),
            owner_id      => $xpc->findvalue( ".//s3:ID",           $node ),
            owner_displayname =>
                $xpc->findvalue( ".//s3:DisplayName", $node ),
            };
    }
    $return->{keys} = \@keys;
    return $return;
}

sub _compat_bucket {
    my ( $self, $conf ) = @_;
    return Net::Amazon::S3::Bucket->new(
        { account => $self, bucket => delete $conf->{bucket} } );
}

=head2 add_key 

DEPRECATED. DO NOT USE

=cut

# compat wrapper; deprecated as of 2005-03-23
sub add_key {
    my ( $self, $conf ) = @_;
    my $bucket = $self->_compat_bucket($conf);
    my $key    = delete $conf->{key};
    my $value  = delete $conf->{value};
    return $bucket->add_key( $key, $value, $conf );
}

=head2 get_key 

DEPRECATED. DO NOT USE

=cut

# compat wrapper; deprecated as of 2005-03-23
sub get_key {
    my ( $self, $conf ) = @_;
    my $bucket = $self->_compat_bucket($conf);
    return $bucket->get_key( $conf->{key} );
}

=head2 head_key 

DEPRECATED. DO NOT USE

=cut

# compat wrapper; deprecated as of 2005-03-23
sub head_key {
    my ( $self, $conf ) = @_;
    my $bucket = $self->_compat_bucket($conf);
    return $bucket->head_key( $conf->{key} );
}

=head2 delete_key 

DEPRECATED. DO NOT USE

=cut

# compat wrapper; deprecated as of 2005-03-23
sub delete_key {
    my ( $self, $conf ) = @_;
    my $bucket = $self->_compat_bucket($conf);
    return $bucket->delete_key( $conf->{key} );
}

# make the HTTP::Request object
sub _make_request {
    my ( $self, $method, $path, $headers, $data, $metadata ) = @_;
    croak 'must specify method' unless $method;
    croak 'must specify path'   unless defined $path;
    $headers  ||= {};
    $data     ||= '';
    $metadata ||= {};

    my $http_headers = $self->_merge_meta( $headers, $metadata );

    $self->_add_auth_header( $http_headers, $method, $path );
    my $protocol = $self->secure ? 'https' : 'http';
    my $url      = "$protocol://s3.amazonaws.com/$path";
    my $request  = HTTP::Request->new( $method, $url, $http_headers );
    $request->content($data);

    # my $req_as = $request->as_string;
    # $req_as =~ s/[^\n\r\x20-\x7f]/?/g;
    # $req_as = substr( $req_as, 0, 1024 ) . "\n\n";

    return $request;
}

# $self->_send_request($HTTP::Request)
# $self->_send_request(@params_to_make_request)
sub _send_request {
    my $self = shift;
    my $request;
    if ( @_ == 1 ) {
        $request = shift;
    } else {
        $request = $self->_make_request(@_);
    }

    my $response = $self->_do_http($request);
    my $content  = $response->content;

    return $content unless $response->content_type eq 'application/xml';
    return unless $content;
    return $self->_xpc_of_content($content);
}

# centralize all HTTP work, for debugging
sub _do_http {
    my ( $self, $request ) = @_;

    # convenient time to reset any error conditions
    $self->err(undef);
    $self->errstr(undef);
    return $self->ua->request($request);
}

sub _send_request_expect_nothing {
    my $self    = shift;
    my $request = $self->_make_request(@_);

    my $response = $self->_do_http($request);
    my $content  = $response->content;

    return 1 if $response->code =~ /^2\d\d$/;

    # anything else is a failure, and we save the parsed result
    $self->_remember_errors( $response->content );
    return 0;
}

sub _xpc_of_content {
    my ( $self, $content ) = @_;
    my $doc = $self->libxml->parse_string($content);

    #warn $doc->toString(2);

    my $xpc = XML::LibXML::XPathContext->new($doc);
    $xpc->registerNs( 's3', 'http://s3.amazonaws.com/doc/2006-03-01/' );

    return $xpc;
}

# returns 1 if errors were found
sub _remember_errors {
    my ( $self, $src ) = @_;
    my $xpc = ref $src ? $src : $self->_xpc_of_content($src);

    if ( $xpc->findnodes("//Error") ) {
        $self->err( $xpc->findvalue("//Error/Code") );
        $self->errstr( $xpc->findvalue("//Error/Message") );
        return 1;
    }
    return 0;
}

sub _add_auth_header {
    my ( $self, $headers, $method, $path ) = @_;
    my $aws_access_key_id     = $self->aws_access_key_id;
    my $aws_secret_access_key = $self->aws_secret_access_key;

    if ( not $headers->header('Date') ) {
        $headers->header( Date => time2str(time) );
    }
    my $canonical_string
        = $self->_canonical_string( $method, $path, $headers );
    my $encoded_canonical
        = $self->_encode( $aws_secret_access_key, $canonical_string );
    $headers->header(
        Authorization => "AWS $aws_access_key_id:$encoded_canonical" );
}

# generates an HTTP::Headers objects given one hash that represents http
# headers to set and another hash that represents an object's metadata.
sub _merge_meta {
    my ( $self, $headers, $metadata ) = @_;
    $headers  ||= {};
    $metadata ||= {};

    my $http_header = HTTP::Headers->new;
    while ( my ( $k, $v ) = each %$headers ) {
        $http_header->header( $k => $v );
    }
    while ( my ( $k, $v ) = each %$metadata ) {
        $http_header->header( "$METADATA_PREFIX$k" => $v );
    }

    return $http_header;
}

# generate a canonical string for the given parameters.  expires is optional and is
# only used by query string authentication.
sub _canonical_string {
    my ( $self, $method, $path, $headers, $expires ) = @_;
    my %interesting_headers = ();
    while ( my ( $key, $value ) = each %$headers ) {
        my $lk = lc $key;
        if (   $lk eq 'content-md5'
            or $lk eq 'content-type'
            or $lk eq 'date'
            or $lk =~ /^$AMAZON_HEADER_PREFIX/ )
        {
            $interesting_headers{$lk} = $self->_trim($value);
        }
    }

    # these keys get empty strings if they don't exist
    $interesting_headers{'content-type'} ||= '';
    $interesting_headers{'content-md5'}  ||= '';

    # just in case someone used this.  it's not necessary in this lib.
    $interesting_headers{'date'} = ''
        if $interesting_headers{'x-amz-date'};

    # if you're using expires for query string auth, then it trumps date
    # (and x-amz-date)
    $interesting_headers{'date'} = $expires if $expires;

    my $buf = "$method\n";
    foreach my $key ( sort keys %interesting_headers ) {
        if ( $key =~ /^$AMAZON_HEADER_PREFIX/ ) {
            $buf .= "$key:$interesting_headers{$key}\n";
        } else {
            $buf .= "$interesting_headers{$key}\n";
        }
    }

    # don't include anything after the first ? in the resource...
    $path =~ /^([^?]*)/;
    $buf .= "/$1";

    # ...unless there is an acl or torrent parameter
    if ( $path =~ /[&?]acl($|=|&)/ ) {
        $buf .= '?acl';
    } elsif ( $path =~ /[&?]torrent($|=|&)/ ) {
        $buf .= '?torrent';
    }

    return $buf;
}

sub _trim {
    my ( $self, $value ) = @_;
    $value =~ s/^\s+//;
    $value =~ s/\s+$//;
    return $value;
}

# finds the hmac-sha1 hash of the canonical string and the aws secret access key and then
# base64 encodes the result (optionally urlencoding after that).
sub _encode {
    my ( $self, $aws_secret_access_key, $str, $urlencode ) = @_;
    my $hmac = Digest::HMAC_SHA1->new($aws_secret_access_key);
    $hmac->add($str);
    my $b64 = encode_base64( $hmac->digest, '' );
    if ($urlencode) {
        return $self->_urlencode($b64);
    } else {
        return $b64;
    }
}

sub _urlencode {
    my ( $self, $unencoded ) = @_;
    return uri_escape( $unencoded, '^A-Za-z0-9_-' );
}


1;

__END__

=head1 ABOUT

This module contains code modified from Amazon that contains the
following notice:

  #  This software code is made available "AS IS" without warranties of any
  #  kind.  You may copy, display, modify and redistribute the software
  #  code either by itself or as incorporated into your code; provided that
  #  you do not remove any proprietary notices.  Your use of this software
  #  code is at your own risk and you waive any claim against Amazon
  #  Digital Services, Inc. or its affiliates with respect to your use of
  #  this software code. (c) 2006 Amazon Digital Services, Inc. or its
  #  affiliates.

=head1 TESTING

Testing S3 is a tricky thing. Amazon wants to charge you a bit of 
money each time you use their service. And yes, testing counts as using.
Because of this, the application's test suite skips anything approaching 
a real test unless you set these three environment variables:

=over 

=item AMAZON_S3_EXPENSIVE_TESTS

Doesn't matter what you set it to. Just has to be set


=item AWS_ACCESS_KEY_ID 

Your AWS access key

=item AWS_ACCESS_KEY_SECRET

Your AWS sekkr1t passkey. Be forewarned that setting this environment variable
on a shared system might leak that information to another user. Be careful.

=back

=head1 AUTHOR

Leon Brocard <acme@astray.com> and unknown Amazon Digital Services programmers.

Brad Fitzpatrick <brad@danga.com> - return values, Bucket object

=head1 SEE ALSO

L<Net::Amazon::S3::Bucket>

