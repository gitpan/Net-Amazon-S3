package Net::Amazon::S3::Bucket;
use strict;
use warnings;
use Carp;
use base qw(Class::Accessor::Fast);
__PACKAGE__->mk_accessors(qw(bucket creation_date account));

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);
    die "no bucket"  unless $self->bucket;
    die "no account" unless $self->account;
    return $self;
}

sub _uri {
    my ( $self, $key ) = @_;
    return $self->bucket . "/" . $self->account->_urlencode($key);
}

# returns bool
sub add_key {
    my ( $self, $key, $value, $conf ) = @_;
    croak 'must specify key' unless $key && length $key;

    return $self->account->_send_request_expect_nothing( 'PUT',
        $self->_uri($key), $conf, $value );
}

sub head_key {
    my ( $self, $key ) = @_;
    return $self->get_key( $key, "HEAD" );
}

# returns undef on missing content,
# death on server errors,
# and hashref of { content_type, etag, value, @meta } on success
sub get_key {
    my ( $self, $key, $method ) = @_;
    $method ||= "GET";
    my $acct = $self->account;

    my $request  = $acct->_make_request( $method, $self->_uri($key), {} );
    my $response = $acct->_do_http($request);

    if ( $response->code == 404 ) {
        return undef;
    }

    unless ( $response->code =~ /^2\d\d$/ ) {
        $acct->err("network_error");
        $acct->errstr( $response->status_line );
        die "Net::Amazon::S3: Amazon responded with "
            . $response->status_line . "\n";
    }

    my $etag = $response->header('ETag');
    if ($etag) {
        $etag =~ s/^"//;
        $etag =~ s/"$//;
    }

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

# returns bool
sub delete_key {
    my ( $self, $key ) = @_;
    croak 'must specify key' unless $key && length $key;
    return $self->account->_send_request_expect_nothing( 'DELETE',
        $self->_uri($key), {} );
}

# delete ourself
sub delete_bucket {
    my $self = shift;
    croak "Unexpected arguments" if @_;
    return $self->account->delete_bucket($self);
}

sub list {
    my $self = shift;
    my $conf = shift || {};
    $conf->{bucket} = $self->bucket;
    return $self->account->list_bucket($conf);
}

# proxy up the err requests
sub err    { $_[0]->account->err }
sub errstr { $_[0]->account->errstr }

1;

__END__

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

=head1 SEE ALSO

L<Net::Amazon::S3>
