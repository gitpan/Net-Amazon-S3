package Net::Amazon::S3;
use strict;
use warnings;
use Carp;
use Digest::HMAC_SHA1;
use HTTP::Date;
use MIME::Base64 qw(encode_base64);
use LWP::UserAgent;
use URI::Escape;
use XML::LibXML;
use XML::LibXML::XPathContext;
use base qw(Class::Accessor::Fast);
__PACKAGE__->mk_accessors(
    qw(libxml aws_access_key_id aws_secret_access_key secure ua));
our $VERSION = '0.30';

my $AMAZON_HEADER_PREFIX = 'x-amz-';
my $METADATA_PREFIX      = 'x-amz-meta-';

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);

    die "No aws_access_key_id"     unless $self->aws_access_key_id;
    die "No aws_secret_access_key" unless $self->aws_secret_access_key;

    $self->secure(0) if not defined $self->secure;

    my $ua = LWP::UserAgent->new;
    $ua->timeout(30);
    $self->ua($ua);
    $self->libxml( XML::LibXML->new );
    return $self;
}

sub buckets {
    my $self = shift;
    my $xpc  = $self->_make_request( 'GET', '', {} );

    my $owner_id          = $xpc->findvalue("//s3:Owner/s3:ID");
    my $owner_displayname = $xpc->findvalue("//s3:Owner/s3:DisplayName");

    #    warn "$owner_id / $owner_displayname";
    my @buckets;
    foreach my $node ( $xpc->findnodes(".//s3:Bucket") ) {
        push @buckets,
            {
            bucket        => $xpc->findvalue( ".//s3:Name",         $node ),
            creation_date => $xpc->findvalue( ".//s3:CreationDate", $node ),
            };

    }
    return {
        owner_id          => $owner_id,
        owner_displayname => $owner_displayname,
        buckets           => \@buckets,
    };
}

sub add_bucket {
    my ( $self, $conf ) = @_;
    my $bucket = $conf->{bucket};
    croak 'must specify bucket' unless $bucket;
    my $xpc = $self->_make_request( 'PUT', $bucket, {} );
}

sub delete_bucket {
    my ( $self, $conf ) = @_;
    my $bucket = $conf->{bucket};
    croak 'must specify bucket' unless $bucket;
    my $xpc = $self->_make_request( 'DELETE', $bucket, {} );
}

sub list_bucket {
    my ( $self, $conf ) = @_;
    my $bucket = $conf->{bucket};
    delete $conf->{bucket};
    croak 'must specify bucket' unless $bucket;
    $conf ||= {};

    my $path = $bucket;
    if (%$conf) {
        $path .= "?"
            . join( '&',
            map { "$_=" . urlencode( $conf->{$_} ) } keys %$conf );
    }

    my $xpc = $self->_make_request( 'GET', $path, {} );

    my $return = {
        bucket       => $xpc->findvalue("//s3:ListBucketResult/s3:Name"),
        prefix       => $xpc->findvalue("//s3:ListBucketResult/s3:Prefix"),
        marker       => $xpc->findvalue("//s3:ListBucketResult/s3:Marker"),
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

sub add_key {
    my ( $self, $conf ) = @_;
    my $bucket = $conf->{bucket};
    my $key    = $conf->{key};
    my $value  = $conf->{value};
    croak 'must specify bucket' unless $bucket;
    croak 'must specify key'    unless $key;
    delete $conf->{bucket};
    delete $conf->{key};
    delete $conf->{value};

    $key = $self->_urlencode($key);

    my $xpc = $self->_make_request( 'PUT', "$bucket/$key", $conf, $value );
}

sub get_key {
    my ( $self, $conf ) = @_;
    my $bucket = $conf->{bucket};
    my $key    = $conf->{key};
    my $method = $conf->{_method} || 'GET';
    croak 'must specify bucket' unless $bucket;
    croak 'must specify key'    unless $key;
    delete $conf->{bucket};
    delete $conf->{key};
    delete $conf->{_method};

    $key = $self->_urlencode($key);

    my $response = $self->_make_request( $method, "$bucket/$key", $conf );

    #    warn $response->as_string;

    my $etag = $response->header('ETag');
    $etag =~ s/^"//;
    $etag =~ s/"$//;

    my $return = {
        content_type => $response->content_type,
        etag         => $etag,
        value        => $response->content,
    };

    foreach my $header ( $response->headers->header_field_names ) {
        next unless $header =~ /x-amz-meta-/i;
        $return->{ lc $header } = $response->header($header);
    }

    return $return;
}

sub head_key {
    my ( $self, $conf ) = @_;
    $conf->{_method} = 'HEAD';
    return $self->get_key($conf);
}

sub delete_key {
    my ( $self, $conf ) = @_;
    my $bucket = $conf->{bucket};
    croak 'must specify bucket' unless $bucket;
    my $key = $conf->{key};
    croak 'must specify key' unless $key;
    my $xpc = $self->_make_request( 'DELETE', "$bucket/$key", {} );
}

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

    #    warn $request->as_string;
    my $response = $self->ua->request($request);

    #    warn $response->as_string;

    my $content = $response->content;

    my ($package,   $filename, $line,       $subroutine, $hasargs,
        $wantarray, $evaltext, $is_require, $hints,      $bitmask
        )
        = caller(1);
    if ( $subroutine eq 'Net::Amazon::S3::get_key' ) {
        if ( $response->code == 404 ) {
            die "key not found";
        } else {
            return $response;
        }
    }
    return $content unless $response->content_type eq 'application/xml';
    return unless $content;
    my $doc = $self->libxml->parse_string($content);

    # warn $doc->toString(2);

    my $xpc = XML::LibXML::XPathContext->new($doc);
    $xpc->registerNs( 's3', 'http://s3.amazonaws.com/doc/2006-03-01/' );

    if ( $xpc->findnodes("//Error") ) {
        carp 'Net::Amazon::S3 error: '
            . $xpc->findvalue("//Error/Code") . " - "
            . $xpc->findvalue("//Error/Message");
    }
    return $xpc;
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
            $interesting_headers{$lk} = $value;
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

=head1 NAME

Net::Amazon::S3 - Use the Amazon S3 - Simple Storage Service

=head1 SYNOPSIS

  use Net::Amazon::S3;
  # this synopsis is presented as a test file
  
  my $s3 = Net::Amazon::S3->new(
      {   aws_access_key_id     => $aws_access_key_id,
          aws_secret_access_key => $aws_secret_access_key
      }
  );

  # list all buckets that i own
  my $response = $s3->buckets;
  is( $response->{owner_id}, '46a801915a1711f...' );
  is( $response->{owner_displayname}, '_acme_' );
  is_deeply($response->{buckets}, []);

  # create a bucket
  my $bucketname = $aws_access_key_id . '-net-amazon-s3-test';
  $s3->add_bucket( { bucket => $bucketname } );
  $response = $s3->buckets;
  ok( ( grep { $_->{bucket} eq $bucketname } @{ $response->{buckets} } );

  # fetch contents of the bucket
  # note prefix, marker, max_keys options can be passed in
  $response = $s3->list_bucket( { bucket => $bucketname } );
  is( $response->{bucket},       $bucketname );
  is( $response->{prefix},       '' );
  is( $response->{marker},       '' );
  is( $response->{max_keys},     1_000 );
  is( $response->{is_truncated}, 0 );
  is_deeply( $response->{keys}, [] );

  # store a key with a content-type and some metadata
  my $keyname = 'testing.txt';
  my $value   = 'T';
  $s3->add_key(
      {   bucket              => $bucketname,
          key                 => $keyname,
          value               => $value,
          content_type        => 'text/plain',
          'x-amz-meta-colour' => 'orange',
      }
  );

  # list keys in the bucket
  $response = $s3->list_bucket( { bucket => $bucketname } );
  is( $response->{bucket},       $bucketname );
  is( $response->{prefix},       '' );
  is( $response->{marker},       '' );
  is( $response->{max_keys},     1_000 );
  is( $response->{is_truncated}, 0 );
  my @keys = @{ $response->{keys} };
  is( @keys, 1 );
  my $key = $keys[0];
  is( $key->{key},  $keyname );
  # the etag is the MD5 of the value
  is( $key->{etag}, 'b9ece18c950afbfa6b0fdbfa4ff731d3' );
  is( $key->{size}, 1 );
  is( $key->{owner_id}, '46a801915a1711f...');
  is( $key->{owner_displayname}, '_acme_' );

  # fetch a key
  $response = $s3->get_key( { bucket => $bucketname, key => $keyname } );
  is( $response->{content_type},        'text/plain' );
  is( $response->{value},               'T' );
  is( $response->{etag},                'b9ece18c950afbfa6b0fdbfa4ff731d3' );
  is( $response->{'x-amz-meta-colour'}, 'orange' );

  # fetch a key's metadata
  $response = $s3->head_key( { bucket => $bucketname, key => $keyname } );
  is( $response->{content_type},        'text/plain' );
  is( $response->{value},               '' );
  is( $response->{etag},                'b9ece18c950afbfa6b0fdbfa4ff731d3' );
  is( $response->{'x-amz-meta-colour'}, 'orange' );

  # delete a key
  $s3->delete_key( { bucket => $bucketname, key => $keyname } );

  # finally delete the bucket
  $s3->delete_bucket( { bucket => $bucketname } );

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

=head1 AUTHOR

Leon Brocard <acme@astray.com> and unknown Amazon Digital Services programmers.
