package Protocol::Redis::Test;

use strict;
use warnings;

require Exporter;

our @ISA    = qw(Exporter);
our @EXPORT = qw(protocol_redis_ok);

use Test::More;
require Carp;

sub protocol_redis_ok {
    my ($redis, $api_version) = @_;

    if ($api_version == 1) {
        _apiv1_ok($redis);
    }
    else {
        Carp::croak(qq/Unknown Protocol::Redis API version $api_version/);
    }
}

sub _apiv1_ok {
    my $redis = shift;

    subtest 'Protocol::Redis APIv1 ok' => sub {
        plan tests => 32;

        can_ok $redis, 'parse', 'use_api', 'on_message', 'encode';

        ok $redis->use_api(1), '$redis->use_api(1)';

        # Parsing method tests
        $redis->on_message(undef);
        _parse_string_ok($redis);
        _parse_bulk_ok($redis);
        _parse_multi_bulk_ok($redis);

        # on_message works
        _on_message_ok($redis);

        # Encoding method tests
        _encode_ok($redis);
      }
}

sub _parse_string_ok {
    my $redis = shift;

    # Simple test
    $redis->parse("+test\r\n");

    is_deeply $redis->get_message,
      {type => '+', data => 'test'},
      'simple message';

    is_deeply $redis->get_message, undef, 'queue is empty';

    $redis->parse(":1\r\n");

    is_deeply $redis->get_message, {type => ':', data => '1'},
      'simple number';

    # Binary test
    $redis->parse(join("\r\n", '$4', pack('C4', 0, 1, 2, 3), ''));

    is_deeply [unpack('C4', $redis->get_message->{data})],
      [0, 1, 2, 3],
      'binary data';

    # Chunked message
    $redis->parse('-tes');
    $redis->parse("t2\r\n");
    is_deeply $redis->get_message,
      {type => '-', data => 'test2'},
      'chunked string';

    # Two messages together
    $redis->parse("+test");
    $redis->parse("1\r\n-test");
    $redis->parse("2\r\n");
    is_deeply
      [$redis->get_message, $redis->get_message],
      [{type => '+', data => 'test1'}, {type => '-', data => 'test2'}],
      'first stick message';

}

sub _parse_bulk_ok {
    my $redis = shift;

    # Bulk message
    $redis->parse("\$4\r\ntest\r\n");
    is_deeply $redis->get_message,
      {type => '$', data => 'test'},
      'simple bulk message';

    $redis->parse("\$5\r\ntes");
    $redis->parse("t2\r\n");
    is_deeply $redis->get_message,
      {type => '$', data => 'test2'},
      'splitted bulk message';

    # Nil bulk message
    $redis->parse("\$-1\r\n");

    is_deeply $redis->get_message,
      {type => '$', data => undef},
      'nil bulk message';

    # splitted bulk message
    $redis->parse(join("\r\n", '$4', 'test', '+OK'));
    $redis->parse("\r\n");
    is_deeply $redis->get_message,
      {type => '$', data => 'test'}, 'splitted message';
    is_deeply $redis->get_message, {type => '+', data => 'OK'};

    # Multi bulk message!
    $redis->parse("*1\r\n\$4\r\ntest\r\n");

    is_deeply $redis->get_message,
      {type => '*', data => [{type => '$', data => 'test'}]},
      'simple multibulk message';
}

sub _parse_multi_bulk_ok {
    my $redis = shift;

    # Multi bulk message with multiple arguments
    $redis->parse("*3\r\n\$5\r\ntest1\r\n");
    $redis->parse("\$5\r\ntest2\r\n");
    $redis->parse("\$5\r\ntest3\r\n");

    is_deeply $redis->get_message,
      { type => '*',
        data => [
            {type => '$', data => 'test1'},
            {type => '$', data => 'test2'},
            {type => '$', data => 'test3'}
        ]
      },
      'multi argument multi-bulk message';

    $redis->parse("*0\r\n");
    is_deeply $redis->get_message,
      {type => '*', data => []},
      'multi-bulk nil result';

    # Does it work?
    $redis->parse("\$4\r\ntest\r\n");
    is_deeply $redis->get_message,
      {type => '$', data => 'test'},
      'everything still works';

    # Multi bulk message with status items
    $redis->parse(join("\r\n", '*2', '+OK', '$4', 'test', ''));
    is_deeply $redis->get_message,
      { type => '*',
        data => [{type => '+', data => 'OK'}, {type => '$', data => 'test'}]
      };

    # splitted multi-bulk
    $redis->parse(join("\r\n", '*1', '$4', 'test', '+OK'));
    $redis->parse("\r\n");

    is_deeply $redis->get_message,
      {type => '*', data => [{type => '$', data => 'test'}]};
    is_deeply $redis->get_message, {type => '+', data => 'OK'};
}

sub _on_message_ok {
    my $redis = shift;

    # Parsing with cb
    my $r = [];
    $redis->on_message(
        sub {
            my ($redis, $message) = @_;

            push @$r, $message;
        }
    );

    $redis->parse("+foo\r\n");
    $redis->parse("\$3\r\nbar\r\n");

    is_deeply $r,
      [{type => '+', data => 'foo'}, {type => '$', data => 'bar'}],
      'parsing with callback';

    $r = [];
    $redis->parse("+foo\r\n\$3\r\nbar\r\n");

    is_deeply $r,
      [{type => '+', data => 'foo'}, {type => '$', data => 'bar'}],
      'parsing with callback';

    $redis->on_message(undef);
}

sub _encode_ok {
    my $redis = shift;

    # Encode message
    is $redis->encode({type => '+', data => 'OK'}), "+OK\r\n",
      'encode status';
    is $redis->encode({type => '-', data => 'ERROR'}), "-ERROR\r\n",
      'encode error';
    is $redis->encode({type => ':', data => '5'}), ":5\r\n", 'encode integer';

    # Encode bulk message
    is $redis->encode({type => '$', data => 'test'}), "\$4\r\ntest\r\n",
      'encode bulk';
    is $redis->encode({type => '$', data => undef}), "\$-1\r\n",
      'encode nil bulk';

    # Encode multi-bulk
    is $redis->encode({type => '*', data => [{type => '$', data => 'test'}]}),
      "\*1\r\n\$4\r\ntest\r\n",
      'encode multi-bulk';
    is $redis->encode(
        {   type => '*',
            data => [
                {type => '$', data => 'test1'}, {type => '$', data => 'test2'}
            ]
        }
      ),
      "\*2\r\n\$5\r\ntest1\r\n\$5\r\ntest2\r\n",
      'encode multi-bulk';

    is $redis->encode({type => '*', data => []}), "\*0\r\n",
      'encode empty multi-bulk';

    is $redis->encode({type => '*', data => undef}), "\*-1\r\n",
      'encode nil multi-bulk';

    is $redis->encode(
        {   type => '*',
            data => [
                {type => '$', data => 'foo'},
                {type => '$', data => undef},
                {type => '$', data => 'bar'}
            ]
        }
      ),
      "\*3\r\n\$3\r\nfoo\r\n\$-1\r\n\$3\r\nbar\r\n",
      'encode multi-bulk with nil element';
}

1;
__END__

=head1 NAME

Protocol::Redis::Test - reusable tests for Protocol::Redis implementations.

=head1 SYNOPSIS

    use Test::More plan => 5;
    use Protocol::Redis::Test;

    use_ok 'Protocol::Redis';
    my $redis = new_ok 'Protocol::Redis';

    # Test Protocol::Redis API 
    protocol_redis_ok $redis, 1;

=head1 DESCRIPTION

Reusable tests for Protocol::Redis implementations.

=head1 FUNCTIONS

=head2 C<protocol_redis_ok>

    protocol_redis_ok $redis, 1;

Check if $redis implementation of Protocol::Redis meets API version 1

=head1 SEE ALSO

L<Protocol::Redis>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010-2011, Sergey Zasenko

This program is free software, you can redistribute it and/or modify it under
the terms of the Artistic License version 2.0.

=cut
