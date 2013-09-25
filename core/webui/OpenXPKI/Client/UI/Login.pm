# OpenXPKI::Client::UI::Login
# Written 2013 by Oliver Welter
# (C) Copyright 2013 by The OpenXPKI Project

package OpenXPKI::Client::UI::Login;

use Moose; 
use Data::Dumper;

extends 'OpenXPKI::Client::UI::Result';

my $meta = __PACKAGE__->meta;

sub BUILD {
    
    my $self = shift;
    $self->_page ({'type' => 'form','label' => 'Please log in.'});    
}

sub init_realm_select {
    
    my $self = shift;
    my $realms = shift;
        
    $self->_result()->{main} = [{ 'action' => 'login.realm', 'fields' => [
        { 'name' => 'pki_realm', 'label' => 'Realm', 'type' => 'select', 'options' => $realms },
    ]}];
    
    return $self;
}

sub init_auth_stack {
    
    my $self = shift;
    my $stacks = shift;
          
    $self->_result()->{main} = [{ 'action' => 'login.stack', 'fields' => [
        { 'name' => 'auth_stack', 'label' => 'Handler', 'type' => 'select', 'options' => $stacks },
    ]}];
    
    return $self;
}

sub init_login_passwd {
    
    my $self = shift;
          
    $self->_result()->{main} = [{ 'action' => 'login.password', 'fields' => [
        { 'name' => 'username', 'label' => 'Username', 'type' => 'text' },
        { 'name' => 'password', 'label' => 'Password', 'type' => 'password' },
    ]}];
    
    return $self;
    
}

sub do_login {
    
    my $self = shift;
    my $args = shift;
    
    my $cgi = $args->{cgi};
    
    
}

1;