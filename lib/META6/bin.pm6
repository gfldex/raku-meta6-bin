use v6.c;

use META6;
use HTTP::Client;
use Git::Config;
use JSON::Tiny;

unit module META6::bin;

# enum ANSI(reset => 0, bold => 1, underline => 2, inverse => 7, black => 30, red => 31, green => 32, yellow => 33, blue => 34, magenta => 35, cyan => 36, white => 37, default => 39, on_black => 40, on_red => 41, on_green   => 42, on_yellow  => 43, on_blue => 44, on_magenta => 45, on_cyan    => 46, on_white   => 47, on_default => 49);

my &BOLD = sub (*@s) {
    "\e[1m{@s.join('')}\e[0m"
}

my &RED = sub (*@s) {
    "\e[31m{@s.join('')}\e[0m"
}

&BOLD = &RED = sub (Stringy $s) { $s } unless $*OUT.t;

my @path = «%*ENV<HOME>/.meta6»».IO;
my $cfg-dir = %*ENV<HOME>.IO.child('.meta6');
my $github-user = git-config<credential><username>;
my $github-realname = git-config<user><name>;
my $github-email = git-config<user><email>;
my $github-token = $cfg-dir.?child('github-token.txt').slurp.chomp // '';

if $cfg-dir.e & !$cfg-dir.d {
    note "WARN: ⟨$cfg-dir⟩ is not a directory.";
}

sub first-hit($basename) {
    @path».child($basename).grep(*.e & *.r).first
}

our sub try-to-fetch-url($_) is export(:HELPER) {
    my $response = HTTP::Client.new.head(.Str, :follow);
    CATCH { default { $response = Nil } }
    200 <= $response.?status < 400
}

our proto sub MAIN(|) is export(:MAIN) {*}

multi sub MAIN(Bool :$check, Str :$meta6-file-name = 'META6.json',
         Bool :$create, Bool :$force,
         Str :$name, Str :$description = '',
         Str :$version = (v0.0.1).Str, Str :$perl = (v6.c).Str,
         Str :$author =  "$github-realname <$github-email>",
         Str :$auth = "github:$github-user",
         Str :$base-dir = '.',
         Bool :$verbose
) {
    my IO::Path $meta6-file = ($base-dir ~ '/' ~ $meta6-file-name).IO;

    if $create {
        die RED "File ⟨$meta6-file⟩ already exists, the --force needs to be with you." if $meta6-file.e && !$force;
        die RED "To create a META6.json --name=<project-name-here> is required." unless $name;

        my $meta6 = META6.new(:$name, :$description, version => Version.new($version), perl-version => Version.new($perl), authors => [$author], :$auth,
                              source-url => "https://github.com/$github-user/{$base-dir}.git",
                              depends => [ "Test::META" ],
                              provides => {}, license => 'Artistic 2.0', production => False);
        $meta6-file.spurt($meta6.to-json);
    }


    if $check {
        my $meta6 = META6.new(file => $meta6-file) or die RED "Failed to process ⟨$meta6-file⟩.";

        
        with $meta6<source-url> {
            if $meta6<source-url> ~~ /^ 'git://' / {
                note RED „WARN: Schema git:// used in source-url. Use https:// to avoid logins and issues thanks to dependence on git.“;
            }
            if !try-to-fetch-url($meta6<source-url>) {
                note RED „WARN: Failed to reach $meta6<source-url>.“;
            }
        }

        if $meta6-file.parent.child('t').child('meta.t').e {
            note RED „WARN: meta.t found but missing Test::META module in "depends"“ unless 'Test::META' ∈ $meta6<depends>
        }
    }
}

multi sub MAIN(Str :$new-module, Bool :$force, Bool :$skip-git, Bool :$skip-github, :$verbose) {
    my $name = $new-module;
    die RED "To create a module --new-module=<Module::Name::Here> is required." unless $name;
    my $base-dir = 'perl6-' ~ $name.subst(:g, '::', '-').fc;
    die RED "Directory ⟨$base-dir⟩ already exists, the --force needs to be with you." if $base-dir.IO.e && !$force;
    say BOLD "Creating new module $name under ⟨$base-dir⟩.";
    $base-dir.IO.mkdir or die RED "Cannot create ⟨$base-dir⟩: $!";

    pre-create-hook($base-dir);

    for <lib t bin example> {
        my $dir = $base-dir ~ '/' ~ .Str;
        $dir.IO.mkdir or die RED "Cannot create ⟨$dir⟩: $!";
    }

    create-readme($base-dir, $name);
    create-meta-t($base-dir);
    create-travis-yml($base-dir);
    create-gitignore($base-dir);
    my @tracked-files =
    copy-skeleton-files($base-dir)».IO».basename;

    @tracked-files.append: 'META6.json', 'README.md', '.travis.yml', '.gitignore', 't/meta.t';

    MAIN(:create, :$name, :$base-dir, :$force);
    git-create($base-dir, @tracked-files) unless $skip-git;
    github-create($base-dir) unless $skip-git && $skip-github;
    
    post-create-hook($base-dir);

    git-push($base-dir, :$verbose) unless $skip-git && $skip-github;

    post-push-hook($base-dir);
}

multi sub MAIN(:$create-cfg-dir, Bool :$force) {
    die RED "⟨$cfg-dir⟩ already exists" if $force ^^ $cfg-dir.e;
    mkdir $cfg-dir;
    
    mkdir "$cfg-dir/skeleton";
    mkdir "$cfg-dir/pre-create.d";
    mkdir "$cfg-dir/post-create.d";
    mkdir "$cfg-dir/post-push.d";

    say BOLD "Created ⟨$cfg-dir⟩.";
}

our sub git-create($base-dir, @tracked-files, :$verbose) is export(:GIT) {
    my Promise $p;

    my $git = Proc::Async.new('git', 'init', $base-dir);
    my $timeout = Promise.at(now + 60);

    await Promise.anyof($p = $git.start, $timeout);
    fail RED "⟨git init⟩ timed out." if $p.status == Broken;
    
    $git = Proc::Async.new('git', '-C', $base-dir, 'add', |@tracked-files);
    $timeout = Promise.at(now + 60);
    
    await Promise.anyof($p = $git.start, $timeout);
    fail RED "⟨git add⟩ timed out." if $p.status == Broken;
    
    $git = Proc::Async.new('git', '-C', $base-dir, 'commit', |@tracked-files, '-m', 'initial commit, add ' ~ @tracked-files.join(', '));
    $timeout = Promise.at(now + 60);
    
    await Promise.anyof($p = $git.start, $timeout);
    fail RED "⟨git commit⟩ timed out." if $p.status == Broken;
}

our sub github-create($base-dir) is export(:GIT) {
    temp $github-user = $github-token ?? $github-user ~ ':' ~ $github-token !! $github-user;
    my $curl = Proc::Async.new('curl', '--silent', '-u', $github-user, 'https://api.github.com/user/repos', '-d', '{"name":"' ~ $base-dir ~ '"}');
    my Promise $p;
    my $github-response;
    $curl.stdout.tap: { $github-response ~= .Str };
    my $timeout = Promise.at(now + 60);

    say BOLD "Creating github repo.";
    await Promise.anyof($p = $curl.start, $timeout);
    fail RED "⟨curl⟩ timed out." if $p.status == Broken;
    
    given from-json($github-response) {
        when .<errors>:exists {
            fail RED .<message>.subst(:g, '.', ''), ": ", .<errors>.[0].<message>.subst('name', $base-dir), '.';
        }
        when .<full_name>:exists {
            say BOLD 'GitHub project created at https://github.com/' ~ .<full_name> ~ '.';
        }
    }
}

our sub git-push($base-dir, :$verbose) is export(:GIT) {
    my Promise $p;

    my $git = Proc::Async.new('git', '-C', $base-dir, 'remote', 'add', 'origin', "https://github.com/$github-user/$base-dir");
    $git.stdout.tap: { Nil } unless $verbose;
    my $timeout = Promise.at(now + 60);
    
    await Promise.anyof($p = $git.start, $timeout);
    fail RED "⟨git remote⟩ timed out." if $p.status == Broken;
    
    say BOLD "Pushing repo to github.";
    $git = Proc::Async.new('git', '-C', $base-dir, 'push', 'origin', 'master');
    $git.stdout.tap: { Nil } unless $verbose;
    $timeout = Promise.at(now + 60);
    
    await Promise.anyof($p = $git.start, $timeout);
    fail RED "⟨git push⟩ timed out." if $p.status == Broken;
}

our sub create-readme($base-dir, $name) is export(:CREATE) {
    spurt("$base-dir/README.md", qq:to<EOH>);
    # $name
    
    [![Build Status](https://travis-ci.org/$github-user/$base-dir.svg?branch=master)](https://travis-ci.org/$github-user/$base-dir)

    ## SYNOPSIS
    
    ```
    use $name;
    ```
    
    ## LICENSE
    
    All files (unless noted otherwise) can be used, modified and redistributed
    under the terms of the Artistic License Version 2. Examples (in the
    documentation, in tests or distributed as separate files) can be considered
    public domain.
    
    ⓒ{ now.Date.year } $github-realname
    EOH
}

our sub create-meta-t($base-dir) is export(:CREATE) {
    spurt("$base-dir/t/meta.t", Q:to<EOH>);
    use v6;
    
    use lib 'lib';
    use Test;
    use Test::META;
    
    meta-ok;
    
    done-testing;
    EOH
}

our sub create-travis-yml($base-dir) is export(:CREATE) {
    spurt("$base-dir/.travis.yml", Q:to<EOH>);
    language: perl6
    sudo: false
    perl6:
        - latest
    install:
        - rakudobrew build-zef
        - zef install .
    EOH
}

our sub create-gitignore($base-dir) is export(:CREATE) {
    spurt("$base-dir/.gitignore", Q:to<EOH>);
    .precomp
    *.swp
    *.bak
    *~
    EOH
}

class X::Proc::Async::Timeout is Exception {
    has $.command;
    has $.seconds;
    method message {
        RED "⟨$.command⟩ timed out after $.seconds seconds.";
    }
}

class Proc::Async::Timeout is Proc::Async is export {
    method start(Numeric :$timeout, |c --> Promise:D) {
        state &parent-start-method = nextcallee;
        start {
            await my $outer-p = Promise.anyof(my $p = parent-start-method(self, |c), Promise.at(now + $timeout));
            if $p.status != Kept {
                self.kill(signal => Signal::SIGKILL);
                fail X::Proc::Async::Timeout.new(command => self.path, seconds => $timeout);
            }
        }
    }
}

our sub copy-skeleton-files($base-dir) is export(:HELPER) {
    my @skeleton-files = $cfg-dir.IO.child('skeleton').dir;

    @skeleton-files».&copy-file($base-dir)
}

our sub copy-file($src is copy, $dst-dir is copy where *.IO.d) is export(:HELPER) {
    $src.=IO;
    my $dst = $dst-dir.IO.child($src.basename);

    try $dst.spurt: $src.slurp or die RED "Can not copy ⟨$src⟩ to ⟨$dst-dir⟩: $!";

    $dst
}

our sub pre-create-hook($base-dir) is export(:HOOK) {
    for $cfg-dir.child('pre-create.d').dir.grep(!*.ends-with('~')).sort {
        await Proc::Async::Timeout.new(.Str, $base-dir.IO.absolute).start: timeout => 60;
    }
}

our sub post-create-hook($base-dir) is export(:HOOK){
    for $cfg-dir.child('post-create.d').dir.grep(!*.ends-with('~')).sort {
        await Proc::Async::Timeout.new(.Str, $base-dir.IO.absolute).start: timeout => 60;
    }
}

our sub post-push-hook($base-dir) is export(:HOOK){
    for $cfg-dir.child('post-push.d').dir.grep(!*.ends-with('~')).sort {
        await Proc::Async::Timeout.new(.Str, $base-dir.IO.absolute).start: timeout => 60;
    }
}
