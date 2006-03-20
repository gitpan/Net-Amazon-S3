use Module::Build;
use strict;

my $build = Module::Build->new(
    create_makefile_pl => 'traditional',
    license            => 'perl',
    module_name        => 'Net::Amazon::S3',
    requires           => {
        'Class::Accessor::Fast'      => '0',
        'DateTime::Format::Strptime' => '0',
        'Digest::HMAC_SHA1'          => '0',
        'HTTP::Date'                 => '0',
        'LWP::UserAgent'             => '0',
        'MIME::Base64'               => '0',
        'URI::Escape'                => '0',
        'Test::More'                 => '0.01',
        'XML::LibXML'                => '0',
        'XML::LibXML::XPathContext'  => '0',
    },
);
$build->create_build_script;
