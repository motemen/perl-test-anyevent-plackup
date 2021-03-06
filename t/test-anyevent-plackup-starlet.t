use strict;
BEGIN {
    my $dir_name = __FILE__; $dir_name =~ s{[^/]+$}{}; $dir_name ||= '.';
    $dir_name .= '/../lib'; unshift @INC, $dir_name;
}
use warnings;
use Test::X1;
use Test::More;
use Test::AnyEvent::plackup;
use Path::Class;
use Web::UserAgent::Functions qw(http_get);

test {
    my $c = shift;

    my $code = q{
        use strict;
        use warnings;
        return sub {
            return [200, ['Content-Type' => 'text/plain'], ['hoge fuga']];
        };
    };

    my $server = Test::AnyEvent::plackup->new;
    $server->server('Starlet');
    $server->set_app_code($code);

    my $cv = AE::cv;
    $cv->begin(sub { $_[0]->send });

    my ($start_cv, $end_cv) = $server->start_server;

    $cv->begin;
    my $port = $server->port;
    $start_cv->cb(sub {
        test {
            http_get 
                url => qq<http://localhost:$port/>,
                anyevent => 1,
                cb => sub {
                    my $res = $_[1];
                    test {
                        is $res->code, 200;
                        $server->stop_server;
                        $cv->end;
                    } $c;
                };
        } $c;
    });

    $cv->begin;
    $end_cv->cb(sub {
        my $return = $_[0]->recv;
        test {
            is $return >> 8, 0;
            http_get 
                url => qq<http://localhost:$port/>,
                anyevent => 1,
                cb => sub {
                    my $res = $_[1];
                    test {
                        like $res->code, qr/^59[56]$/;
                        $cv->end;
                    } $c;
                };
        } $c;
    });

    $cv->end;
    $cv->cb(sub {
        test {
            done $c;
        } $c;
    });
} name => 'server', n => 3;

run_tests;
