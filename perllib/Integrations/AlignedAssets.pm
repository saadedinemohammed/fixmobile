package Integrations::AlignedAssets;
# Generated by SOAP::Lite (v1.27) for Perl -- soaplite.com
# Copyright (C) 2000-2006 Paul Kulchenko, Byrne Reese
# -- generated at [Thu Jun 15 09:34:14 2023]
# -- generated from https://webhost.aligned-assets.co.uk/cbeds/webservices/v2/searchservice.asmx?WSDL

my $endpoint = 'https://webhost.aligned-assets.co.uk/cbeds/webservices/v2/searchservice.asmx'

my %methods = (
'Search' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/Search',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'adapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'token', type => 'tns:QueryToken', attr => {}),
    ], # end parameters
  }, # end Search
'SpatialRadialSearchByEastingNorthing' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/SpatialRadialSearchByEastingNorthing',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'adapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'easting', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'northing', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'unit', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'distance', type => 's:string', attr => {}),
    ], # end parameters
  }, # end SpatialRadialSearchByEastingNorthing
'SpatialBoundarySearch' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/SpatialBoundarySearch',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'adapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'boundary', type => 's:string', attr => {}),
    ], # end parameters
  }, # end SpatialBoundarySearch
'AdvancedCustomSearch' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/AdvancedCustomSearch',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'adapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'token', type => 'tns:QueryToken', attr => {}),
    ], # end parameters
  }, # end AdvancedCustomSearch
'PredictiveSearchForStreet' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/PredictiveSearchForStreet',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'adapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'searchText', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'language', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'streetType', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'rowsReturned', type => 's:string', attr => {}),
    ], # end parameters
  }, # end PredictiveSearchForStreet
'SinglelineSearch' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/SinglelineSearch',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'adapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'searchText', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'boundaryId', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'showNationalData', type => 's:boolean', attr => {}),
    ], # end parameters
  }, # end SinglelineSearch
'PoliceXdmSearch' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/PoliceXdmSearch',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'adapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'searchText', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'easting', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'northing', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'unit', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'distance', type => 's:string', attr => {}),
    ], # end parameters
  }, # end PoliceXdmSearch
'MultiAdapterSearch' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/MultiAdapterSearch',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'multiAdapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'token', type => 'tns:QueryToken', attr => {}),
    ], # end parameters
  }, # end MultiAdapterSearch
'SimpleSearch' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/SimpleSearch',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'adapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'searchText', type => 's:string', attr => {}),
    ], # end parameters
  }, # end SimpleSearch
'AdvancedSearch' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/AdvancedSearch',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'adapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'searchText', type => 's:string', attr => {}),
    ], # end parameters
  }, # end AdvancedSearch
'SpatialBoundarySimpleSearch' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/SpatialBoundarySimpleSearch',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'adapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'searchText', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'boundaryId', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'showNationalData', type => 's:string', attr => {}),
    ], # end parameters
  }, # end SpatialBoundarySimpleSearch
'SpatialRadialSearchbyLatLong' => {
    endpoint => $endpoint,
    soapaction => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService/SpatialRadialSearchbyLatLong',
    namespace => 'http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService',
    parameters => [
      SOAP::Data->new(name => 'apiKey', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'AdapterName', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'Latitude', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'Longitude', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'Unit', type => 's:string', attr => {}),
      SOAP::Data->new(name => 'Distance', type => 's:string', attr => {}),
    ], # end parameters
  }, # end SpatialRadialSearchbyLatLong
); # end my %methods

use SOAP::Lite;
use Exporter;
use Carp ();

use vars qw(@ISA $AUTOLOAD @EXPORT_OK %EXPORT_TAGS);
@ISA = qw(Exporter SOAP::Lite);
@EXPORT_OK = (keys %methods);
%EXPORT_TAGS = ('all' => [@EXPORT_OK]);

sub _call {
    my ($self, $method) = (shift, shift);
    my $name = UNIVERSAL::isa($method => 'SOAP::Data') ? $method->name : $method;
    my %method = %{$methods{$name}};
    $self->proxy($method{endpoint} || Carp::croak "No server address (proxy) specified")
        unless $self->proxy;
    my @templates = @{$method{parameters}};
    my @parameters = ();
    foreach my $param (@_) {
        if (@templates) {
            my $template = shift @templates;
            my ($prefix,$typename) = SOAP::Utils::splitqname($template->type);
            my $method = 'as_'.$typename;
            # TODO - if can('as_'.$typename) {...}
            my $result = $self->serializer->$method($param, $template->name, $template->type, $template->attr);
            push(@parameters, $template->value($result->[2]));
        }
        else {
            push(@parameters, $param);
        }
    }
    $self->endpoint($method{endpoint})
       ->ns($method{namespace})
       ->on_action(sub{qq!"$method{soapaction}"!});
  $self->serializer->register_ns("http://www.w3.org/2001/XMLSchema","s");
  $self->serializer->register_ns("http://schemas.xmlsoap.org/soap/encoding/","soapenc");
  $self->serializer->register_ns("http://schemas.xmlsoap.org/wsdl/http/","http");
  $self->serializer->register_ns("http://schemas.xmlsoap.org/wsdl/","wsdl");
  $self->serializer->register_ns("http://schemas.xmlsoap.org/wsdl/mime/","mime");
  $self->serializer->register_ns("http://schemas.xmlsoap.org/wsdl/soap12/","soap12");
  $self->serializer->register_ns("http://www.aligned-assets.co.uk/SinglePoint/Search/WebServices/V2/SearchService","tns");
  $self->serializer->register_ns("http://microsoft.com/wsdl/mime/textMatching/","tm");
    my $som = $self->SUPER::call($method => @parameters);
    if ($self->want_som) {
        return $som;
    }
    UNIVERSAL::isa($som => 'SOAP::SOM') ? wantarray ? $som->paramsall : $som->result : $som;
}

sub BEGIN {
    no strict 'refs';
    for my $method (qw(want_som)) {
        my $field = '_' . $method;
        *$method = sub {
            my $self = shift->new;
            @_ ? ($self->{$field} = shift, return $self) : return $self->{$field};
        }
    }
}
no strict 'refs';
for my $method (@EXPORT_OK) {
    my %method = %{$methods{$method}};
    *$method = sub {
        my $self = UNIVERSAL::isa($_[0] => __PACKAGE__)
            ? ref $_[0]
                ? shift # OBJECT
                # CLASS, either get self or create new and assign to self
                : (shift->self || __PACKAGE__->self(__PACKAGE__->new))
            # function call, either get self or create new and assign to self
            : (__PACKAGE__->self || __PACKAGE__->self(__PACKAGE__->new));
        $self->_call($method, @_);
    }
}

sub AUTOLOAD {
    my $method = substr($AUTOLOAD, rindex($AUTOLOAD, '::') + 2);
    return if $method eq 'DESTROY' || $method eq 'want_som';
    die "Unrecognized method '$method'. List of available method(s): @EXPORT_OK\n";
}

1;
