
use strict;
use warnings;



use ExtUtils::MakeMaker 6.30;



my %WriteMakefileArgs = (
  "ABSTRACT" => "Use the Amazon S3 - Simple Storage Service",
  "AUTHOR" => "Pedro Figueiredo <me\@pedrofigueiredo.org>",
  "BUILD_REQUIRES" => {},
  "CONFIGURE_REQUIRES" => {
    "ExtUtils::MakeMaker" => "6.30"
  },
  "DISTNAME" => "Net-Amazon-S3",
  "EXE_FILES" => [
    "bin/s3cl"
  ],
  "LICENSE" => "perl",
  "NAME" => "Net::Amazon::S3",
  "PREREQ_PM" => {
    "Carp" => 0,
    "Data::Stream::Bulk::Callback" => 0,
    "DateTime::Format::HTTP" => 0,
    "Digest::HMAC_SHA1" => 0,
    "Digest::MD5" => 0,
    "Digest::MD5::File" => 0,
    "File::Find::Rule" => 0,
    "File::stat" => 0,
    "Getopt::Long" => 0,
    "HTTP::Date" => 0,
    "HTTP::Status" => 0,
    "IO::File" => "1.14",
    "LWP::UserAgent::Determined" => 0,
    "MIME::Base64" => 0,
    "MIME::Types" => 0,
    "Moose" => "0.85",
    "Moose::Util::TypeConstraints" => 0,
    "MooseX::StrictConstructor" => "0.16",
    "MooseX::Types::DateTime::MoreCoercions" => "0.07",
    "Path::Class" => 0,
    "Pod::Usage" => 0,
    "Regexp::Common" => 0,
    "Term::Encoding" => 0,
    "Term::ProgressBar::Simple" => 0,
    "URI" => 0,
    "URI::Escape" => 0,
    "URI::QueryParam" => 0,
    "XML::LibXML" => 0,
    "XML::LibXML::XPathContext" => 0,
    "strict" => 0,
    "warnings" => 0
  },
  "TEST_REQUIRES" => {
    "File::Find" => 0,
    "File::Temp" => 0,
    "LWP::Simple" => 0,
    "Test::Exception" => 0,
    "Test::More" => 0,
    "vars" => 0
  },
  "VERSION" => "0.60",
  "test" => {
    "TESTS" => "t/*.t"
  }
);


unless ( eval { ExtUtils::MakeMaker->VERSION(6.63_03) } ) {
  my $tr = delete $WriteMakefileArgs{TEST_REQUIRES};
  my $br = $WriteMakefileArgs{BUILD_REQUIRES};
  for my $mod ( keys %$tr ) {
    if ( exists $br->{$mod} ) {
      $br->{$mod} = $tr->{$mod} if $tr->{$mod} > $br->{$mod};
    }
    else {
      $br->{$mod} = $tr->{$mod};
    }
  }
}

unless ( eval { ExtUtils::MakeMaker->VERSION(6.56) } ) {
  my $br = delete $WriteMakefileArgs{BUILD_REQUIRES};
  my $pp = $WriteMakefileArgs{PREREQ_PM};
  for my $mod ( keys %$br ) {
    if ( exists $pp->{$mod} ) {
      $pp->{$mod} = $br->{$mod} if $br->{$mod} > $pp->{$mod};
    }
    else {
      $pp->{$mod} = $br->{$mod};
    }
  }
}

delete $WriteMakefileArgs{CONFIGURE_REQUIRES}
  unless eval { ExtUtils::MakeMaker->VERSION(6.52) };

WriteMakefile(%WriteMakefileArgs);



