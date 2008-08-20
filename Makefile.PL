#!perl
use strict;
use warnings;
use ExtUtils::MakeMaker;
WriteMakefile(
    NAME         => 'Net::Amazon::S3',
    VERSION_FROM => 'lib/Net/Amazon/S3.pm',
    AUTHOR       => 'Leon Brocard <acme@astray.com>',
    LICENSE      => 'perl',
    PREREQ_PM    => {
        'Class::Accessor::Fast'      => '0',
        'Digest::MD5::File'          => '0',
        'Digest::HMAC_SHA1'          => '0',
        'HTTP::Date'                 => '0',
        'IO::File'                   => '1.14',
        'LWP::UserAgent::Determined' => '0',
        'MIME::Base64'               => '0',
        'Test::More'                 => '0.01',
        'XML::LibXML'                => '0',
        'XML::LibXML::XPathContext'  => '0',
        'URI::Escape'                => '0',
    }
);

