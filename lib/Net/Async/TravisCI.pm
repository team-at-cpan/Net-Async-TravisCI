package Net::Async::TravisCI;

use strict;
use warnings;

use parent qw(IO::Async::Notifier);

use Future;
use URI;
use URI::Template;
use JSON::MaybeXS;
use Syntax::Keyword::Try;

use File::ShareDir ();
use Log::Any qw($log);
use Path::Tiny ();

use Net::Async::Pusher;

use Net::Async::TravisCI::Account;
use Net::Async::TravisCI::Annotation;
use Net::Async::TravisCI::Branch;
use Net::Async::TravisCI::Commit;
use Net::Async::TravisCI::Config;
use Net::Async::TravisCI::Job;
use Net::Async::TravisCI::Build;

my $json = JSON::MaybeXS->new;

sub configure {
	my ($self, %args) = @_;
	for my $k (grep exists $args{$_}, qw(token)) {
		$self->{$k} = delete $args{$k};
	}
	$self->SUPER::configure(%args);
}

sub endpoints {
	my ($self) = @_;
	$self->{endpoints} ||= $json->decode(
		Path::Tiny::path(
			'share/endpoints.json' //
			File::ShareDir::dist_file(
				'Net-Async-Github',
				'endpoints.json'
			)
		)->slurp_utf8
	);
}

sub endpoint {
	my ($self, $endpoint, %args) = @_;
	URI::Template->new($self->endpoints->{$endpoint . '_url'})->process(%args);
}

sub http {
	my ($self) = @_;
	$self->{http} ||= do {
		require Net::Async::HTTP;
		$self->add_child(
			my $ua = Net::Async::HTTP->new(
				fail_on_error            => 1,
				max_connections_per_host => 2,
				pipeline                 => 1,
				max_in_flight            => 8,
				decode_content           => 1,
				timeout                  => 30,
				user_agent               => 'Mozilla/4.0 (perl; https://metacpan.org/pod/Net::Async::TravisCI; TEAM@cpan.org)',
			)
		);
		$ua
	}
}

sub auth_info {
	my ($self) = @_;
	if(my $key = $self->api_key) {
		return (
			user => $self->api_key,
			pass => '',
		);
	} elsif(my $token = $self->token) {
		return (
			headers => {
				Authorization => 'token "' . $token . '"'
			}
		)
	}
	return;
}

sub api_key { shift->{api_key} }
sub token { shift->{token} }

sub mime_type { shift->{mime_type} //= 'application/vnd.travis-ci.2+json' }
sub base_uri { shift->{base_uri} //= URI->new('https://api.travis-ci.com') }

sub http_get {
	my ($self, %args) = @_;
	my %auth = $self->auth_info;

	if(my $hdr = delete $auth{headers}) {
		$args{headers}{$_} //= $hdr->{$_} for keys %$hdr
	}
	$args{headers}{Accept} //= $self->mime_type;
	$args{$_} //= $auth{$_} for keys %auth;

	$log->tracef("GET %s { %s }", ''. $args{uri}, \%args);
    $self->http->GET(
        (delete $args{uri}),
		%args
    )->then(sub {
        my ($resp) = @_;
        return { } if $resp->code == 204;
        return { } if 3 == ($resp->code / 100);
        try {
			warn "have " . $resp->as_string("\n");
            return Future->done($json->decode($resp->decoded_content))
        } catch {
            $log->errorf("JSON decoding error %s from HTTP response %s", $@, $resp->as_string("\n"));
            return Future->fail($@ => json => $resp);
        }
    })->else(sub {
        my ($err, $src, $resp, $req) = @_;
        $src //= '';
        if($src eq 'http') {
            $log->errorf("HTTP error %s, request was %s with response %s", $err, $req->as_string("\n"), $resp->as_string("\n"));
        } else {
            $log->errorf("Other failure (%s): %s", $src // 'unknown', $err);
        }
        Future->fail(@_);
    })
}

sub http_post {
	my ($self, %args) = @_;
	my %auth = $self->auth_info;

	if(my $hdr = delete $auth{headers}) {
		$args{headers}{$_} //= $hdr->{$_} for keys %$hdr
	}
	$args{headers}{Accept} //= $self->mime_type;
	$args{$_} //= $auth{$_} for keys %auth;

	my $content = delete $args{content};
	$content = $json->encode($content) if ref $content;

	$log->tracef("POST %s { %s }", ''. $args{uri}, $content, \%args);
    $self->http->POST(
        (delete $args{uri}),
		$content,
		content_type => 'application/json',
		%args
    )->then(sub {
        my ($resp) = @_;
        return Future->done({ }) if $resp->code == 204;
        return Future->done({ }) if 3 == ($resp->code / 100);
        try {
			warn "have " . $resp->as_string("\n");
            return Future->done($json->decode($resp->decoded_content))
        } catch {
            $log->errorf("JSON decoding error %s from HTTP response %s", $@, $resp->as_string("\n"));
            return Future->fail($@ => json => $resp);
        }
    })->else(sub {
        my ($err, $src, $resp, $req) = @_;
        $src //= '';
        if($src eq 'http') {
            $log->errorf("HTTP error %s, request was %s with response %s", $err, $req->as_string("\n"), $resp->as_string("\n"));
        } else {
            $log->errorf("Other failure (%s): %s", $src // 'unknown', $err);
        }
        Future->fail(@_);
    })
}

sub github_token {
	my ($self, %args) = @_;
	$self->http_post(
		uri => URI->new($self->base_uri . '/auth/github'),
		content => {
			github_token => delete $args{token}
		}
	)->transform(
		done => sub { shift->{access_token} },
	)
}

sub accounts {
	my ($self, %args) = @_;
	$self->http_get(
		uri => URI->new($self->base_uri . '/accounts'),
	)->transform(
		done => sub { map Net::Async::TravisCI::Account->new(%$_), @{ shift->{accounts} } },
	)
}

sub users {
	my ($self, %args) = @_;
	$self->http_get(
		uri => URI->new($self->base_uri . '/users'),
#	)->transform(
#		done => sub { map Net::Async::TravisCI::Account->new(%$_), @{ shift->{accounts} } },
	)
}

sub jobs {
	my ($self, %args) = @_;
	$self->http_get(
		uri => URI->new($self->base_uri . '/jobs'),
	)->transform(
		done => sub { map Net::Async::TravisCI::Job->new(%$_), @{ shift->{jobs} } },
	)
}

sub cancel_job {
	my ($self, $job, %args) = @_;
	$self->http_post(
		uri => URI->new($self->base_uri . '/jobs/' . $job->id . '/cancel'),
		content => { },
	)->transform(
		done => sub { },
	)
}

sub pusher_auth {
	my ($self, %args) = @_;
	$self->pusher->then(sub {
		my ($conn) = @_;
		$conn->connected->then(sub {
			$log->tracef("Pusher socket ID is %s", $conn->socket_id);
			Future->done($conn->socket_id)
		})
	})->then(sub {
		$args{socket_id} = shift or die "need a socket ID";
		$self->http_post(
			uri => URI->new($self->base_uri . '/pusher/auth'),
			content => \%args
		)
	})->transform(done => sub {
		shift->{channels}
	})
}

sub pusher {
	my ($self) = @_;
	$self->{pusher} //= $self->config->then(sub {
		my $key = shift->pusher->{key};
		$self->add_child(
			my $pusher = Net::Async::Pusher->new
		);
		$pusher->connect(
			key => $key,
		)
	});
}

sub config {
	my ($self, %args) = @_;
	$self->{config} //= $self->http_get(
		uri => URI->new($self->base_uri . '/config'),
	)->transform(
		done => sub { map Net::Async::TravisCI::Config->new(%$_), shift->{config} },
	)
}

1;
