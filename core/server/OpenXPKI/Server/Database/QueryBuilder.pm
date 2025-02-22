package OpenXPKI::Server::Database::QueryBuilder;
use Moose;
use utf8;
=head1 Name

OpenXPKI::Server::Database::QueryBuilder - Programmatic interface to SQL queries

=cut

use OpenXPKI::Debug;
use OpenXPKI::Server::Database::Query;
use OpenXPKI::MooseParams;
use SQL::Abstract::More; # TODO Use SQL::Maker instead of SQL::Abstract::More? (but the former only supports Oracle type LIMITs)

################################################################################
# Attributes
#

# Constructor arguments

has 'driver' => (
    is => 'ro',
    does => 'OpenXPKI::Server::Database::Role::Driver',
    required => 1,
);

has 'sqlam' => ( # SQL query builder
    is => 'ro',
    isa => 'SQL::Abstract::More',
    required => 1,
);

has 'namespace' => ( # database namespace (i.e. schema) to prepend to tables
    is => 'ro',
    isa => 'Str',
);

################################################################################
# Methods
#

# Prefixes the given DB table name with a namespace (if there's not already
# one part of the table name)
sub _add_namespace_to {
    my ($self, $obj_param) = positional_args(\@_, # OpenXPKI::MooseParams
        { isa => 'Str | ArrayRef[Str]' },
    );
    # no namespace defined
    return $obj_param unless $self->namespace;
    # make sure we always have an ArrayRef
    my $obj_list = ref $obj_param eq 'ARRAY' ? $obj_param : [ $obj_param ];
    # add namespace if there's not already a namespace in the object name
    $obj_list = [ map { m/\./ ? $_ : $self->namespace.'.'.$_ } @$obj_list ];
    # return same type as argument was (ArrayRef or scalar)
    return ref $obj_param eq 'ARRAY' ? $obj_list : $obj_list->[0];
}

# Calls the given SQL::Abstract::More method after converting the parameters.
# Sets $self->sql_str and $self->sql_params
sub _make_query {
    my ($self, %params) = named_args(\@_,   # OpenXPKI::MooseParams
        method    => { isa => 'Str' },
        args      => { isa => 'HashRef' },
        query_obj => { isa => 'OpenXPKI::Server::Database::Query', optional => 1 },
    );
    my $method = $params{method};
    my $args = $params{args};
    my $query = $params{query_obj} // OpenXPKI::Server::Database::Query->new;

    # Workaround for passing literal WHERE queries.
    # Required because:
    #  - SQL::Abstract::More expects a Scalar while (the later invoked)
    #  - SQL::Abstract       expects a ScalarRef.
    # So we expect a ScalarRef and wrap it for SQL::Abstract::More.
    my $is_scalar_ref = $args->{where} && ref $args->{where} eq 'SCALAR';
    if ($is_scalar_ref) {
        $args->{where} = { -and => [ $args->{where} ] }; # wrap ScalarRef in innocuous query
    }

    # Prefix arguments with dash "-"
    my %sqlam_args = map { '-'.$_ => $args->{$_} } keys %$args;

    ##! 4: "SQL::Abstract::More->$method(" . join(", ", map { sprintf "%s = %s", $_, Data::Dumper->new([$sqlam_args{$_}])->Indent(0)->Terse(1)->Dump } sort keys %sqlam_args) . ")"

    # Call SQL::Abstract::More method and store results
    my ($sql, @bind) = $self->sqlam->$method(%sqlam_args);

    # Custom SQL replacements to support non-standard SQL (e.g. FROM_UNIXTIME)
    $sql = $self->driver->do_sql_replacements($sql);

    $query->string($sql);
    $query->add_params(@bind); # there might already be bind values from a JOIN

    return $query;
}

sub select {
    my ($self, %params) = named_args(\@_,   # OpenXPKI::MooseParams
        columns   => { isa => 'ArrayRef[Str]' },
        from      => { isa => 'Str | ArrayRef[Str]', optional => 1 },
        from_join => { isa => 'Str', optional => 1 },
        where     => { isa => 'ScalarRef | ArrayRef | HashRef', optional => 1 },
        group_by  => { isa => 'Str | ArrayRef', optional => 1 },
        having    => { isa => 'Str | ArrayRef | HashRef', optional => 1, depends => ['group_by'] },
        order_by  => { isa => 'Str | ArrayRef', optional => 1 },
        limit     => { isa => 'Int', optional => 1 },
        offset    => { isa => 'Int', optional => 1 },
        distinct  => { isa => 'Bool', optional => 1 },
    );

    # FIXME order_by: if ArrayRef then check for "asc" and "desc" as they are reserved words (https://metacpan.org/pod/SQL::Abstract::More#select)

    OpenXPKI::Exception->throw(message => "There must be at least one column name in 'columns'")
        unless scalar @{$params{'columns'}} > 0;

    OpenXPKI::Exception->throw(message => "Either 'from' or 'from_join' must be specified")
        unless ($params{'from'} or $params{'from_join'});

    # Add namespace to table name
    $params{'from'} = $self->_add_namespace_to($params{'from'}) if $params{'from'};

    if ($params{'distinct'}) {
        delete $params{'distinct'};
        $params{'columns'} = [ -distinct => @{$params{'columns'}} ];
    }

    # Provide nicer syntax for joins than SQL::Abstract::More
    # TODO Test JOIN syntax (especially ON conditions, see https://metacpan.org/pod/SQL::Abstract::More#join)
    my $query;
    if ($params{'from_join'}) {
        die "You cannot specify 'from' and 'from_join' at the same time"
            if $params{'from'};
        my @join_spec = split(/\s+/, $params{'from_join'});
        delete $params{'from_join'};
        # Add namespace to table names (= all even indexes in join spec list)
        for (my $i=0; $i<scalar(@join_spec); $i+=2) {
            my @parts = split /\|/, $join_spec[$i];   # "table" / "table|alias"
            $parts[0] = $self->_add_namespace_to($parts[0]);
            $join_spec[$i] = join '|', @parts;
        }
        # Translate JOIN spec into SQL syntax - taken from SQL::Abstract::More->select.
        # (string is converted into the list that SQL::Abstract::More->join expects)
        my $join_info = $self->sqlam->join(@join_spec);
        $params{'from'} = \($join_info->{sql});

        if ($join_info) {
            $query = OpenXPKI::Server::Database::Query->new;
            $query->add_params( @{$join_info->{bind}} );
        }
    }

    return $self->_make_query(
        method => 'select',
        args => \%params,
        $query ? (query_obj => $query) : ()
    );
}

sub subselect {
    my ($self, $operator, $query) = positional_args(\@_, # OpenXPKI::MooseParams
        { isa => 'Str' },
        { isa => 'HashRef' },
    );

    my $subquery = $self->select(%$query);
    my $subquery_and_op = sprintf "%s (%s)", $operator, $subquery->string;

    return \[ $subquery_and_op => @{ $subquery->params }]
}

sub insert {
    my ($self, %params) = named_args(\@_,   # OpenXPKI::MooseParams
        into     => { isa => 'Str' },
        values   => { isa => 'HashRef' },
    );

    # Add namespace to table name
    $params{'into'} = $self->_add_namespace_to($params{'into'}) if $params{'into'};

    return $self->_make_query(method => 'insert', args => \%params);
}

sub update {
    my ($self, %params) = named_args(\@_,   # OpenXPKI::MooseParams
        table => { isa => 'Str' },
        set   => { isa => 'HashRef' },
        where => { isa => 'ScalarRef | ArrayRef | HashRef' }, # require WHERE clause to prevent accidential updates on all rows
    );
    # Add namespace to table name
    $params{'table'} = $self->_add_namespace_to($params{'table'});

    return $self->_make_query(method => 'update', args => \%params);
}

sub delete {
    my ($self, %params) = named_args(\@_,   # OpenXPKI::MooseParams
        from      => { isa => 'Str' },
        where     => { isa => 'ScalarRef | ArrayRef | HashRef', optional => 1 },
        all       => { isa => 'Bool', optional => 1 },
    );
    OpenXPKI::Exception->throw(message => "Either 'where' or 'all' must be specified")
        unless ($params{'where'} or $params{'all'});

    OpenXPKI::Exception->throw(message => "Empty parameter 'where' not allowed, use 'all' to enforce deletion of all rows")
        if ($params{'where'} and (
            ( ref $params{'where'} eq "ARRAY" and not scalar @{$params{'where'}} )
            or
            ( ref $params{'where'} eq "HASH" and not scalar keys %{$params{'where'}} )
        ));

    # Add namespace to table name
    $params{'from'} = $self->_add_namespace_to($params{'from'}) if $params{'from'};

    # Delete all rows
    if ($params{'all'}) {
        $params{'where'} = {};
        delete $params{'all'};
    }

    return $self->_make_query(method => 'delete', args => \%params);
}

__PACKAGE__->meta->make_immutable;

=head1 Description

This class provides methods to create DBMS specific SQL queries that can be
executed later on.

It delegates most of the work to L<SQL::Abstract::More> but offers a slightly
modified and stripped down interface (customized for OpenXPKI).

=head1 Attributes

=head2 Constructor parameters

=over

=item * B<sqlam> - SQL query builder (an instance of L<SQL::Abstract::More>)

=item * B<namespace> - namespace (i.e. schema) to prepend to table names (I<Str>, optional)

=back

=head1 Methods

=head2 new

Constructor.

Named parameters: see L<attributes section above|/"Constructor parameters">.



=head2 select

Builds a SELECT query and returns a L<OpenXPKI::Server::Database::Query> object
which contains SQL string and bind parameters.

The method parameters are documented in L<OpenXPKI::Server::Database/select>.



=head2 subselect

Builds a subselect to be used within another query and returns a reference to an I<ArrayRef>.

This will take something like this:

    CTX('dbi')->subselect('IN' => {
        from => 'nature',
        columns => [ 'id', 'fruit' ],
        where => { type => 'forbidden' }
    })

and turn it into:

    \[ "IN ($query)" => @bind ]

The method parameters are documented in L<OpenXPKI::Server::Database/subselect>.



=head2 insert

Builds an INSERT query and returns a L<OpenXPKI::Server::Database::Query> object
which contains SQL string and bind parameters.

Named parameters:

=over

=item * B<into> - Table name (I<Str>, required)

=item * B<values> - Hash with column name / value pairs. Please note that C<undef> is interpreted as C<NULL> (I<HashRef>, required)

=back



=head2 update

Builds an UPDATE query and returns a L<OpenXPKI::Server::Database::Query> object
which contains SQL string and bind parameters.

A WHERE clause is required to prevent accidential updates of all rows in a table.

The method parameters are documented in L<OpenXPKI::Server::Database/update>.



=head2 delete

Builds a DELETE query and returns an L<OpenXPKI::Server::Database::Query> object
which contains SQL string and bind parameters.

To prevent accidential deletion of all rows of a table you must specify
parameter C<all> if you want to do that:

    $dbi->delete(
        from => "mytab",
        all => 1,
    );

The method parameters are documented in L<OpenXPKI::Server::Database/delete>.

=cut
