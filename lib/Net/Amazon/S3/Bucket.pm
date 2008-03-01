package Net::Amazon::S3::Bucket;
use strict;
use warnings;
use Carp;
use File::stat;
use IO::File;
use base qw(Class::Accessor::Fast);
__PACKAGE__->mk_accessors(qw(bucket creation_date account));

=head1 NAME

Net::Amazon::S3::Bucket - convenience object for working with Amazon S3 buckets

=head1 SYNOPSIS

  use Net::Amazon::S3;

  my $bucket = $s3->bucket("foo");

  ok($bucket->add_key("key", "data"));
  ok($bucket->add_key("key", "data", {
     content_type => "text/html",
    'x-amz-meta-colour' => 'orange',
  });

  # the err and errstr methods just proxy up to the Net::Amazon::S3's
  # objects err/errstr methods.
  $bucket->add_key("bar", "baz") or
      die $bucket->err . $bucket->errstr;

  # fetch a key
  $val = $bucket->get_key("key");
  is( $val->{value},               'data' );
  is( $val->{content_type},        'text/html' );
  is( $val->{etag},                'b9ece18c950afbfa6b0fdbfa4ff731d3' );
  is( $val->{'x-amz-meta-colour'}, 'orange' );

  # returns undef on missing or on error (check $bucket->err)
  is(undef, $bucket->get_key("non-existing-key"));
  die $bucket->errstr if $bucket->err;

  # fetch a key's metadata
  $val = $bucket->head_key("key");
  is( $val->{value},               '' );
  is( $val->{content_type},        'text/html' );
  is( $val->{etag},                'b9ece18c950afbfa6b0fdbfa4ff731d3' );
  is( $val->{'x-amz-meta-colour'}, 'orange' );

  # delete a key
  ok($bucket->delete_key($key_name));
  ok(! $bucket->delete_key("non-exist-key"));

  # delete the entire bucket (Amazon requires it first be empty)
  $bucket->delete_bucket;
 
=head1 DESCRIPTION

This module represents an S3 bucket.  You get a bucket object
from the Net::Amazon::S3 object.

=head1 METHODS

=head2 new

Create a new bucket object. Expects a hash containing these two arguments:

=over

=item bucket

=item account

=back

=cut

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);
    croak "no bucket"  unless $self->bucket;
    croak "no account" unless $self->account;
    return $self;
}

sub _uri {
    my ( $self, $key ) = @_;
    return ($key)
        ? $self->bucket . "/" . $self->account->_urlencode($key)
        : $self->bucket . "/";
}

=head2 add_key

Takes three positional parameters:

=over

=item key

=item value

=item configuration

A hash of configuration data for this key. (See synopsis);

=back

Returns a boolean.

=cut

# returns bool
sub add_key {
    my ( $self, $key, $value, $conf ) = @_;
    croak 'must specify key' unless $key && length $key;

    if ( $conf->{acl_short} ) {
        $self->account->_validate_acl_short( $conf->{acl_short} );
        $conf->{'x-amz-acl'} = $conf->{acl_short};
        delete $conf->{acl_short};
    }

    if ( ref($value) eq 'SCALAR' ) {
        $conf->{'Content-Length'} ||= -s $$value;
        $value = _content_sub($$value);
    } else {
        $conf->{'Content-Length'} ||= length $value;
    }

    # If we're pushing to a bucket that's under DNS flux, we might get a 307
    # Since LWP doesn't support actually waiting for a 100 Continue response,
    # we'll just send a HEAD first to see what's going on

    if ( ref($value) ) {
        return $self->account->_send_request_expect_nothing_probed( 'PUT',
            $self->_uri($key), $conf, $value );
    } else {
        return $self->account->_send_request_expect_nothing( 'PUT',
            $self->_uri($key), $conf, $value );
    }
}

=head2 add_key_filename

Use this to upload a large file to S3. Takes three positional parameters:

=over

=item key

=item filename

=item configuration

A hash of configuration data for this key. (See synopsis);

=back

Returns a boolean.

=cut

sub add_key_filename {
    my ( $self, $key, $value, $conf ) = @_;
    return $self->add_key( $key, \$value, $conf );
}

=head2 head_key KEY

Takes the name of a key in this bucket and returns its configuration hash

=cut

sub head_key {
    my ( $self, $key ) = @_;
    return $self->get_key( $key, "HEAD" );
}

=head2 get_key $key_name [$method]

Takes a key name and an optional HTTP method (which defaults to C<GET>.
Fetches the key from AWS.

On failure:

Returns undef on missing content, throws an exception (dies) on server errors.

On success:

Returns a hashref of { content_type, etag, value, @meta } on success

=cut

sub get_key {
    my ( $self, $key, $method, $filename ) = @_;
    $method ||= "GET";
    $filename = $$filename if ref $filename;
    my $acct = $self->account;

    my $request = $acct->_make_request( $method, $self->_uri($key), {} );
    my $response = $acct->_do_http( $request, $filename );

    if ( $response->code == 404 ) {
        return undef;
    }

    $acct->_croak_if_response_error($response);

    my $etag = $response->header('ETag');
    if ($etag) {
        $etag =~ s/^"//;
        $etag =~ s/"$//;
    }

    my $return = {
        content_length => $response->content_length || 0,
        content_type   => $response->content_type,
        etag           => $etag,
        value          => $response->content,
    };

    foreach my $header ( $response->headers->header_field_names ) {
        next unless $header =~ /x-amz-meta-/i;
        $return->{ lc $header } = $response->header($header);
    }

    return $return;

}

=head2 get_key_filename $key_name $method $filename

Use this to download large files from S3. Takes a key name and an optional 
HTTP method (which defaults to C<GET>. Fetches the key from AWS and writes
it to the filename. THe value returned will be empty.

On failure:

Returns undef on missing content, throws an exception (dies) on server errors.

On success:

Returns a hashref of { content_type, etag, value, @meta } on success

=cut

sub get_key_filename {
    my ( $self, $key, $method, $filename ) = @_;
    return $self->get_key( $key, $method, \$filename );
}

=head2 delete_key $key_name

Removes C<$key> from the bucket. Forever. It's gone after this.

Returns true on success and false on failure

=cut

# returns bool
sub delete_key {
    my ( $self, $key ) = @_;
    croak 'must specify key' unless $key && length $key;
    return $self->account->_send_request_expect_nothing( 'DELETE',
        $self->_uri($key), {} );
}

=head2 delete_bucket

Delete the current bucket object from the server. Takes no arguments. 

Fails if the bucket has anything in it.

This is an alias for C<$s3->delete_bucket($bucket)>

=cut

sub delete_bucket {
    my $self = shift;
    croak "Unexpected arguments" if @_;
    return $self->account->delete_bucket($self);
}

=head2 list

List all keys in this bucket.

see L<Net::Amazon::S3/list_bucket> for documentation of this method.

=cut

sub list {
    my $self = shift;
    my $conf = shift || {};
    $conf->{bucket} = $self->bucket;
    return $self->account->list_bucket($conf);
}

=head2 list_all

List all keys in this bucket without having to worry about
'marker'. This may make multiple requests to S3 under the hood.

see L<Net::Amazon::S3/list_bucket_all> for documentation of this method.

=cut

sub list_all {
    my $self = shift;
    my $conf = shift || {};
    $conf->{bucket} = $self->bucket;
    return $self->account->list_bucket_all($conf);
}

=head2 get_acl

Takes one optional positional parameter

=over

=item key (optional)

If no key is specified, it returns the acl for the bucket.

=back

Returns an acl in XML format.

=cut

sub get_acl {
    my ( $self, $key ) = @_;
    my $acct = $self->account;

    my $request
        = $acct->_make_request( 'GET', $self->_uri($key) . '?acl', {} );
    my $response = $acct->_do_http($request);

    if ( $response->code == 404 ) {
        return undef;
    }

    $acct->_croak_if_response_error($response);

    return $response->content;
}

=head2 set_acl

Takes a configuration hash_ref containing:

=over

=item acl_xml (cannot be used in conjuction with acl_short)

An XML string which contains access control information which matches
Amazon's published schema.  There is an example of one of these XML strings
in the tests for this module.

=item acl_short (cannot be used in conjuction with acl_xml)

You can use the shorthand notation instead of specifying XML for
certain 'canned' types of acls.

(from the Amazon API documentation)

private: Owner gets FULL_CONTROL. No one else has any access rights.
This is the default.

public-read:Owner gets FULL_CONTROL and the anonymous principal is granted
READ access. If this policy is used on an object, it can be read from a
browser with no authentication.

public-read-write:Owner gets FULL_CONTROL, the anonymous principal is
granted READ and WRITE access. This is a useful policy to apply to a bucket,
if you intend for any anonymous user to PUT objects into the bucket.

authenticated-read:Owner gets FULL_CONTROL, and any principal authenticated
as a registered Amazon S3 user is granted READ access.

=item key (optional)

If the key is not set, it will apply the acl to the bucket.

=back

Returns a boolean.

=cut

sub set_acl {
    my ( $self, $conf ) = @_;
    $conf ||= {};

    unless ( $conf->{acl_xml} || $conf->{acl_short} ) {
        croak "need either acl_xml or acl_short";
    }

    if ( $conf->{acl_xml} && $conf->{acl_short} ) {
        croak "cannot provide both acl_xml and acl_short";
    }

    my $path = $self->_uri( $conf->{key} ) . '?acl';

    my $hash_ref
        = ( $conf->{acl_short} )
        ? { 'x-amz-acl' => $conf->{acl_short} }
        : {};

    my $xml = $conf->{acl_xml} || '';

    return $self->account->_send_request_expect_nothing( 'PUT', $path,
        $hash_ref, $xml );

}

=head2 get_location_constraint

Retrieves the location constraint set when the bucket was created. Returns a
string (eg, 'EU'), or undef if no location constraint was set.

=cut

sub get_location_constraint {
    my ($self) = @_;

    my $xpc = $self->account->_send_request( 'GET',
        $self->bucket . '/?location' );
    return undef unless $xpc && !$self->account->_remember_errors($xpc);

    my $lc = $xpc->findvalue("//s3:LocationConstraint");
    if ( defined $lc && $lc eq '' ) {
        $lc = undef;
    }
    return $lc;
}

# proxy up the err requests

=head2 err

The S3 error code for the last error the object ran into

=cut

sub err { $_[0]->account->err }

=head2 errstr

A human readable error string for the last error the object ran into

=cut

sub errstr { $_[0]->account->errstr }

sub _content_sub {
    my $filename  = shift;
    my $stat      = stat($filename);
    my $remaining = $stat->size;
    my $blksize   = $stat->blksize || 4096;

    croak "$filename not a readable file with fixed size"
        unless -r $filename and $remaining;
    my $fh = IO::File->new( $filename, 'r' )
        or croak "Could not open $filename: $!";
    $fh->binmode;

    return sub {
        my $buffer;

        # upon retries the file is closed and we must reopen it
        unless ( $fh->opened ) {
            $fh = IO::File->new( $filename, 'r' )
                or croak "Could not open $filename: $!";
            $fh->binmode;
            $remaining = $stat->size;
        }

        # warn "read remaining $remaining";
        unless ( my $read = $fh->read( $buffer, $blksize ) ) {

#                       warn "read $read buffer $buffer remaining $remaining";
            croak
                "Error while reading upload content $filename ($remaining remaining) $!"
                if $! and $remaining;

            # otherwise, we found EOF
            $fh->close
                or croak "close of upload content $filename failed: $!";
            $buffer ||= ''
                ;    # LWP expects an emptry string on finish, read returns 0
        }
        $remaining -= length($buffer);
        return $buffer;
    };
}

1;

__END__

=head1 SEE ALSO

L<Net::Amazon::S3>

