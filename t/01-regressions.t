use strict;
use warnings;
use Test::More;
use Net::IMAP::Client;

{
    package Local::ScriptedClient;
    our @ISA = ('Net::IMAP::Client');
    sub _send_cmd { ++$_[0]->{_cmd_id} }
    sub _socket_getline { shift @{$_[0]->{replies}} }
    sub _reconnect_if_needed { 0 }
    sub DESTROY { }
}

sub client {
    return bless {
        _cmd_id => 0,
        selected_folder => 'INBOX',
        FOLDERS => { INBOX => { messages => 10 } },
        notifications => [],
        replies => [ @_ ],
    }, 'Local::ScriptedClient';
}

subtest 'informational OK replies' => sub {
    my $imap = client(
        "* OK Still working.\r\n",
        "NIC1 OK Copy completed\r\n",
    );
    my $ok = eval { $imap->copy([1], 'Trash') };
    is($@, '', 'plain untagged OK does not throw');
    ok($ok, 'COPY succeeds despite progress reply');
    is_deeply($imap->{FOLDERS}{INBOX}{sflags} || {}, {},
        'plain OK does not invent response-code state');
    is_deeply($imap->{notifications}, [], 'progress does not invent a mailbox event');

    $imap = client("* OK [UIDNEXT 23] Next UID\r\n", "NIC1 OK done\r\n");
    ok($imap->copy([1], 'Trash'), 'bracketed OK is accepted');
    is($imap->{FOLDERS}{INBOX}{sflags}{UIDNEXT}, 23, 'response code retained');

    # Use the public fetch method to ensure a trailing progress reply is
    # consumed, rather than becoming an empty result alongside the body.
    $imap = client(
        "* 1 FETCH (RFC822 {4}\r\n",
        ")\r\n",
        "* OK Still working.\r\n",
        "NIC1 OK done\r\n",
    );
    {
        no warnings 'redefine';
        local *Local::ScriptedClient::_read_literal = sub { my $body = 'mail'; return \$body };
        my $bodies = eval { $imap->get_rfc822_body([1]) };
        is($@, '', 'fetch with trailing progress does not throw');
        is(scalar @{$bodies || []}, 1, 'trailing progress leaves only one fetch result');
        is($bodies && $bodies->[0] ? ${$bodies->[0]} : undef, 'mail', 'message body preserved');
    }
};

subtest 'SEARCH and SORT response groups' => sub {
    my @replies = (
        "* OK Working.\r\n",
        "* SEARCH 12 34\r\n",
        "* OK Working again.\r\n",
        "* SEARCH 56\r\n",
        "NIC1 OK Search completed\r\n",
    );
    my $imap = client(@replies);
    is_deeply($imap->search('ALL'), [12, 34, 56],
        'collects SEARCH results across response groups and progress replies');

    $imap = client("* SEARCH\r\n", "NIC1 OK done\r\n");
    is_deeply($imap->search('ALL'), [], 'successful empty search remains an empty array');

    $imap = client("* SORT 34 12 56\r\n", "NIC1 OK done\r\n");
    is_deeply($imap->search('ALL', 'SUBJECT'), [34, 12, 56], 'SORT order preserved');


    $imap = client("NIC1 NO Search denied\r\n");
    ok(!defined $imap->search('ALL'), 'failed search still returns undef');
    is($imap->last_error, 'Search denied', 'server error preserved');

    # This stub isolates search from notification handling. It also checks
    # that examining results does not modify the original response lines.
    {
        no warnings 'redefine';
        my $groups = [["* NO Waiting for a lock\r\n"], ["* SEARCH 9\r\n"]];
        local *Local::ScriptedClient::_tell_imap = sub { return (1, $groups) };
        $imap = client();
        is_deeply($imap->search('ALL'), [9], 'finds results after unrelated response group');
        is($groups->[1][0], "* SEARCH 9\r\n", 'does not edit response text');
        $groups = [["* sort 34 12\r\n"]];
        is_deeply($imap->search('ALL', 'SUBJECT'), [34, 12],
            'result matching is case insensitive');
    }
};

subtest 'Deleted flags and mailbox counts' => sub {
    my $imap = client();
    for (1 .. 2) {
        $imap->_handle_notification(['*', 3, 'FETCH', ['UID', 42, 'FLAGS', ['\\Deleted']]]);
    }
    is($imap->{FOLDERS}{INBOX}{messages}, 10, 'repeated Deleted flags leave message count unchanged');
    ok($imap->{notifications}[0]{deleted}, 'deleted notification retained');
    is($imap->{notifications}[0]{uid}, 42, 'notification UID retained');
    $imap->_handle_notification(['*', 3, 'FETCH', ['FLAGS', []]]);
    is($imap->{FOLDERS}{INBOX}{messages}, 10, 'clearing Deleted leaves count unchanged');
    $imap->_handle_notification(['*', 3, 'EXPUNGE']);
    is($imap->{FOLDERS}{INBOX}{messages}, 9, 'EXPUNGE decreases count once');
    ok($imap->{notifications}[-1]{destroyed}, 'destroyed notification retained');
};

{
    package Local::Socket;
    our @ISA = ('IO::Socket::INET');
    sub sockopt { 1 }
    sub getline {
        my ($self) = @_;
        die "Unexpected second greeting read\n" if $self->{reads}++;
        return "* OK Server ready\r\n";
    }
    sub DESTROY { }

    package Local::ReconnectClient;
    our @ISA = ('Net::IMAP::Client');
    sub login { push @{$_[0]->{actions}}, 'login'; return 1 }
    sub select { push @{$_[0]->{actions}}, "select $_[1]"; return 1 }
    sub DESTROY { }
}

subtest 'reconnection reads one greeting' => sub {
    my $socket = bless { reads => 0 }, 'Local::Socket';
    my $imap = bless {
        server => 'unused.invalid', port => 143, timeout => 1,
        ssl => 0, ssl_options => {}, ssl_verify_peer => 0,
        selected_folder => 'INBOX', actions => [],
    }, 'Local::ReconnectClient';
    {
        no warnings 'redefine';
        local *IO::Socket::INET::new = sub { $socket };
        my $ok = eval { $imap->_reconnect_if_needed(1) };
        is($@, '', 'reconnect does not attempt a second greeting read');
        ok($ok, 'reconnect succeeds');
    }
    is($socket->{reads}, 1, 'exactly one greeting consumed');
    is($imap->{greeting}, "* OK Server ready\r\n", 'greeting retained');
    is_deeply($imap->{actions}, ['login', 'select INBOX'],
        'login and mailbox reselection follow the greeting');
};

done_testing();
