package Net::Async::TravisCI::Branch;

use strict;
use warnings;

sub new { bless { @_[1..$#_] }, $_[0] }

=head2 id

=cut

sub id { shift->{id} }

=head2 repository_id

=cut

sub repository_id { shift->{repository_id} }

=head2 commit_id

=cut

sub commit_id { shift->{commit_id} }

=head2 number

=cut

sub number { shift->{number} }

=head2 config

=cut

sub config { shift->{config} }

=head2 state

=cut

sub state { shift->{state} }

=head2 started_at

=cut

sub started_at { shift->{started_at} }

=head2 finished_at

=cut

sub finished_at { shift->{finished_at} }

=head2 duration

=cut

sub duration { shift->{duration} }

=head2 job_ids

=cut

sub job_ids { shift->{job_ids} }

=head2 pull_request

=cut

sub pull_request { shift->{pull_request} }


1;

