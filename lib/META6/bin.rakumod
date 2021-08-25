use v6.c;

use META6;
use HTTP::Client;
use Git::Config;
use JSON::Fast;

META6.^can('to-json')[0].wrap(-> |c { callwith |c, :sorted-keys});

unit module META6::bin;

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

# enum ANSI(reset => 0, bold => 1, underline => 2, inverse => 7, black => 30, red => 31, green => 32, yellow => 33, blue => 34, magenta => 35, cyan => 36, white => 37, default => 39, on_black => 40, on_red => 41, on_green   => 42, on_yellow  => 43, on_blue => 44, on_magenta => 45, on_cyan    => 46, on_white   => 47, on_default => 49);

our &BOLD is export(:TERM) = sub (*@s) {
    "\e[1m{@s.join('')}\e[0m"
}

our &RED is export(:TERM) = sub (*@s) {
    "\e[31m{@s.join('')}\e[0m"
}

our &RESET is export(:TERM) = sub (*@s) {
    "\e[0m{@s.join('')}\e[0m"
}

&BOLD = &RED = &RESET = sub (Stringy $s) { $s } unless $*OUT.t;

my $git-config = git-config;

my @path = "%*ENV<HOME>/.meta6"».IO;
my $cfg-dir = %*ENV<HOME>.IO.child('.meta6');
my $github-user = $git-config<credential><username> // warn BOLD "Could not read github username from ⟨{$git-config.path}⟩";
my $github-realname = $git-config<user><name>;
my $github-email = $git-config<user><email>;
my $github-token = (try $cfg-dir.child('github-token.txt').slurp.chomp) // '';

if $cfg-dir.e & !$cfg-dir.d {
    note "WARN: ⟨$cfg-dir⟩ is not a directory.";
}

sub first-hit($basename) {
    try @path».child($basename).grep({.e & .r}).first
}

my %cfg = |read-cfg(Any), |read-cfg(first-hit('meta6.cfg'));

my $timeout = %cfg<general><timeout>.Int // 60;
my $git-timeout = %cfg<git><timeout>.Int // $timeout // 120;

our sub try-to-fetch-url($_) is export(:HELPER) {
    return True if %cfg<check><disable-url-check>;

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
                              provides => {}, license => 'Artistic-2.0', production => False);
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
            note RED „WARN: meta.t found but missing Test::META module in "depends"“ unless 'Test::META' ∈ $meta6<depends>;
        }

        given $meta6<auth> {
            when Any:U { note RED „No auth field in ⟨$meta6-file⟩.“ }
            when .Str ~~ / „github:“ (\w+) / {
                my $github-user = $0;
                note RED „Github user: "$github-user" seams not to exist.“ unless try-to-fetch-url("http://github.com/$github-user");
            }
            default { note RED „Unrecognised auth field in ⟨$meta6-file⟩.“; }
        }
    }
}

multi sub MAIN(Str :$new-module, Bool :$force, Bool :$skip-git, Bool :$skip-github, :$skip-skeleton, Str :$prefix is copy, :$verbose, :$description = '') {
    my $name = $new-module;
    $prefix //= %cfg<create><prefix>;
    my @tracked-files;
    
    die RED "To create a module --new-module=<Module::Name::Here> is required." unless $name;
    my $base-dir = $prefix ~ $name.subst(:g, '::', '-').fc;
    die RED "Directory ⟨$base-dir⟩ already exists, the --force needs to be with you." if $base-dir.IO.e && !$force;
    say BOLD "Creating new module $name under ⟨$base-dir⟩.";
    $base-dir.IO.mkdir or die RED "Cannot create ⟨$base-dir⟩: $!";

    pre-create-hook($base-dir);
    unless $skip-skeleton {

        for <lib t bin example> {
            my $dir = $base-dir ~ '/' ~ .Str;
            $dir.IO.mkdir or die RED "Cannot create ⟨$dir⟩: $!";
        }

        create-readme($base-dir, $name);
        create-meta-t($base-dir);
        create-travis-yml($base-dir);
    }

    create-gitignore($base-dir);
    @tracked-files.append: '.gitignore';

    unless $skip-skeleton {
        @tracked-files.append: copy-skeleton-files($base-dir)».IO».basename;

        @tracked-files.append: 'META6.json', 'README.md', '.travis.yml', 't/meta.t';

        MAIN(:create, :$name, :$base-dir, :$force, :$description);
    }

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

    spurt("$cfg-dir/.meta6.cfg", qq:to<EOH>);
    # META6::bin config file
    
    general.timeout = 60
    check.disable-url-check = 0
    git.timeout = 120
    git.protocol = https
    github.issues.timeout = 30
    
    EOH

    say BOLD "Created ⟨$cfg-dir⟩.";
}

multi sub MAIN(:$fork-module, :$force, :v(:$verbose)) {
    my $module-url;
    if $fork-module ~~ /^ [ 'https://' || 'http:// ' ] / {
        $module-url = $fork-module;
    } else {
        my @ecosystem = fetch-ecosystem(:$verbose);
        my $meta6 = @ecosystem.grep(*.<name> eq $fork-module)[0] // fail(„Module ⟨$fork-module⟩ not found in ecosystem.“);
        my $module-url = $meta6<support><source> // $meta6<source-url> // fail(„No source URL found in ecosystem response.“);
    }
    my ($owner, $repo) = $module-url.split('/')[3,4];
    $repo.=subst(/'.git'$/, '');
    my $repo-url = github-fork($owner, $repo);
    my $base-dir = git-clone($repo-url) // fail(„No target URL returned by github clone.“);
    note BOLD "Cloned repo ready in ⟨$base-dir⟩.";
    note RED "WARN: no META6.json found" unless "$base-dir/META6.json".IO.e;
    if "$base-dir/META6.json".IO.e && !"$base-dir/t/meta.t".IO.e {
        note BOLD "No t/meta.t found.";
        create-meta-t($base-dir);
        MAIN(add-dep => 'Test::META', :$base-dir);
        git-add('t/meta.t', :$base-dir);
        git-commit(['t/meta.t', 'META6.json'], 'add t/meta.t', :$base-dir);
    }
}

multi sub MAIN(Str :$add-dep, Str :$base-dir = '.', Str :$meta6-file-name = 'META6.json') {
   my IO::Path $meta6-file = ($base-dir ~ '/' ~ $meta6-file-name).IO;
   my $meta6 = read-meta6($meta6-file) or die RED "Failed to process ⟨$meta6-file⟩.";

   sub simple-version(Str $s is copy) {
       my ($n, $v) = $s.split(':ver');
       with $v {
           $v = Version.new($v) if $v;
           $s = $n;
       } else {
           $v = Version.new(*);
       }
       $s but role :: { method version { $v } }
   }

   if my $stored-dep = ($meta6<depends>.grep: *.&simple-version eq $add-dep.&simple-version).first {
       if $stored-dep.&simple-version.version > $add-dep.&simple-version.version { 
           note BOLD "Dependency to $add-dep younger then version already in META6.json.";
           return
       } else {
           $meta6<depends> = ($meta6<depends>.grep: *.&simple-version !eq $add-dep.&simple-version).Array;
       }
   }

   # (note BOLD "Dependency to $add-dep already in META6.json."; return) if $add-dep.&simple-version ∈ $meta6<depends>».&simple-version;

   $meta6<depends>.push($add-dep);
   $meta6-file.spurt($meta6.to-json);
}

multi sub MAIN(Str :$add-author, Str :$base-dir = '.', Str :$meta6-file-name = 'META6.json') {
   my IO::Path $meta6-file = ($base-dir ~ '/' ~ $meta6-file-name).IO;
   my $meta6 = META6.new(file => $meta6-file) or die RED "Failed to process ⟨$meta6-file⟩.";

   (note BOLD "Author $add-author already in META6.json."; return) if $add-author ∈ $meta6<authors>;

   $meta6<authors>.push($add-author);
   $meta6-file.spurt($meta6.to-json);
}

multi sub MAIN(Str :$set-license, Str :$base-dir = '.', Str :$meta6-file-name = 'META6.json') {
   my IO::Path $meta6-file = ($base-dir ~ '/' ~ $meta6-file-name).IO;
   my $meta6 = META6.new(file => $meta6-file) or die RED "Failed to process ⟨$meta6-file⟩.";

   (note BOLD "License already set to $set-license in META6.json."; return) if $meta6<license> && $set-license eq $meta6<license>;

   $meta6<license> = $set-license;
   $meta6-file.spurt($meta6.to-json);
}

multi sub MAIN(Bool :pr(:$pull-request), Str :$base-dir = '.', Str :$meta6-file-name = 'META6.json',
               Str :$title is copy, Str :$message = '', Str :$head = 'master', Str :$base = 'master', Str :$repo-name
) {
    $title //= git-log(:$base-dir).first;
    my IO::Path $meta6-file = ($base-dir ~ '/' ~ $meta6-file-name).IO;
    die RED "Can not find ⟨$meta6-file⟩." unless $meta6-file.e;
    my $meta6 = META6.new(file => $meta6-file) or die RED "Failed to process ⟨$meta6-file⟩.";
    my $github-url = $meta6<source-url> // $meta6<support>.source;
    my $repo = $repo-name // $github-url.split('/')[4].subst(/'.git'$/, '');

    my ($parent-owner, $parent) = github-get-repo($github-user, $repo)<parent><full_name>.split('/');

    github-pull-request($parent-owner, $parent, $title, $message, :head("$github-user:$head"), :$base);
}

multi sub MAIN(Str :$module, Bool :$issues!, Bool :$closed, Bool :$one-line, Bool :$url, Bool :$deps,
    Str :$base-dir = '.', Str :$meta6-file-name = 'META6.json', :v(:$verbose)
) {
    my ($owner, $repo) = ($module
        ?? query-module($module, :$verbose)
        !! local-module
    ).<owner repo>;

    $repo.=subst(/'.git'$/, '');
    my @issues := github-get-issues($owner, $repo, :$closed);

    for @issues {
        if $one-line {
            my %divider{Int} = 1 => 's', 60 => 'm', 60*60 => 'h', 60*60*24 => 'd', 60*60*24*365 => 'y';
            .<age> = (now.DateTime - DateTime.new(.<created_at>)).Int;
            my $divider = %divider.keys.grep(-> $k { (.<age> div $k) > 0 }).max;
            ($divider, my $unit) = %divider{$divider}:kv;
            my $url-text = $url ?? " ⟨{.<html_url>}⟩" !! '';
            put "[{.<state>}] {.<title>} [{.<age> div $divider}{$unit}]$url-text";
        } else {
            put "[{.<state>}] {.<title>}";
            put "⟨{.<html_url>}⟩";
            put .<body>.indent(4);
        }
    }

    if $deps {
        for query-deps($module, :$base-dir, :$meta6-file-name, :$verbose) {
            say "{.Str}";
            try MAIN(:module(.Str), :issues, :$closed, :$one-line, :$url, :$base-dir, :$meta6-file-name, :$verbose);
        }
    }
}

multi sub MAIN(Bool :$release!, :$version? is copy,
    Str :$base-dir = '.', Str :$meta6-file-name = 'META6.json', :v(:$verbose)
) {
    # FIXME check if we are on master
    my IO::Path $meta6-file = ($base-dir ~ '/' ~ $meta6-file-name).IO;
    my $meta6 = META6.new(file => $meta6-file) or die RED "Failed to process ⟨$meta6-file⟩.";

    given $version {
        my $v := $meta6.version;
        when '+' { $version = Version.new: ($v.parts[0], $v.parts[1], $v.parts[2].succ).join('.'); }
        when '++' { $version = Version.new: ($v.parts[0], $v.parts[1].succ, 0).join('.'); }
        when '+++' { $version = Version.new: ($v.parts[0].succ, 0, 0).join('.'); }
        when .defined { 
            $version = Version.new($version.subst(/^ 'v'/, ''));
        }
        default { $version = $meta6.version; }
    }
    $meta6.version = $version;

    my $owner = $github-user;
    my $name = $meta6.name;
    my $prefix = %cfg<create><prefix>;

    my $repo = $prefix ~ $name.subst(:g, '::', '-').fc;
    my $tag = $repo ~ '-' ~ $version;

    $meta6.source-url = "https://github.com/$owner/$repo/archive/" ~ $tag ~ '.tar.gz';

    $meta6.production = True;

    $meta6-file.spurt($meta6.to-json);

    git-commit([$meta6-file], "releasing as $version", :$base-dir, :$verbose);

    git-tag($tag, :$base-dir, :$verbose);
    git-push($base-dir, :$verbose);
    git-push-tag($tag, :$base-dir);

    github-create-release($owner, $repo, $tag);
}

our sub git-create($base-dir, @tracked-files, :$verbose) is export(:GIT) {
    my Promise $p;

    my $git = Proc::Async.new('git', 'init', $base-dir);
    my $timeout = Promise.at(now + $git-timeout);

    await Promise.anyof($p = $git.start, $timeout);
    fail RED "⟨git init⟩ timed out." if $p.status == Broken;
    
    $git = Proc::Async.new('git', '-C', $base-dir, 'add', |@tracked-files);
    $timeout = Promise.at(now + $git-timeout);
    
    await Promise.anyof($p = $git.start, $timeout);
    fail RED "⟨git add⟩ timed out." if $p.status == Broken;
    
    $git = Proc::Async.new('git', '-C', $base-dir, 'commit', |@tracked-files, '-m', 'initial commit, add ' ~ @tracked-files.join(', '));
    $timeout = Promise.at(now + $git-timeout);
    
    await Promise.anyof($p = $git.start, $timeout);
    fail RED "⟨git commit⟩ timed out." if $p.status == Broken;
}

our sub github-create($base-dir) is export(:GIT) {
    temp $github-user = $github-token ?? $github-user ~ ':' ~ $github-token !! $github-user;
    my $curl = Proc::Async.new('curl', '--silent', '-u', $github-user, 'https://api.github.com/user/repos', '-d', '{"name":"' ~ $base-dir ~ '"}');
    my Promise $p;
    my $github-response;
    $curl.stdout.tap: { $github-response ~= .Str };
    my $timeout = Promise.at(now + $git-timeout);

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

our sub github-fork($owner, $repo) is export(:GIT) {
    temp $github-user = $github-token ?? $github-user ~ ':' ~ $github-token !! $github-user;
    my $curl = Proc::Async::Timeout.new('curl', '--silent', '-u', $github-user, '-X', 'POST', „https://api.github.com/repos/$owner/$repo/forks“);
    my $github-response;
    $curl.stdout.tap: { $github-response ~= .Str };

    say BOLD "Forking github repo from $repo.";
    await $curl.start: :$timeout;
    
    given from-json($github-response) {
        when .<message>:exists {
            fail RED .<message>;
        }
        when .<full_name>:exists {
            say BOLD 'GitHub project forked at https://github.com/' ~ .<full_name> ~ '.';
            return .<html_url>;
        }
    }
}

our sub github-get-repo($owner, $repo) is export(:GIT) {
    temp $github-user = $github-token ?? $github-user ~ ':' ~ $github-token !! $github-user;
    my $curl = Proc::Async::Timeout.new('curl', '--silent', '-u', $github-user, '-X', 'GET', „https://api.github.com/repos/$owner/$repo“);
    my $github-response;
    $curl.stdout.tap: { $github-response ~= .Str };

    await $curl.start: :$timeout;
    
    given from-json($github-response) {
        when .<message>:exists {
            fail RED .<message>;
        }
        when .<full_name>:exists {
            return .item;
        }
    }
}

our sub github-pull-request($owner, $repo, $title, $body = '', :$head = 'master', :$base = 'master') is export(:GIT) {
    temp $github-user = $github-token ?? $github-user ~ ':' ~ $github-token !! $github-user;
    my $curl = Proc::Async::Timeout.new('curl', '--silent', '--user', $github-user, '--request', 'POST', '--data', to-json({ title => $title, body => $body, head => $head, base => $base}), „https://api.github.com/repos/$owner/$repo/pulls“);
    my $github-response;
    $curl.stdout.tap: { $github-response ~= .Str };

    say BOLD "Creating pull request.";
    await $curl.start: :$timeout;

    given from-json($github-response) {
        when .<message>:exists {
            fail RED .<message> ~ RESET ~ ' (You may have forgot to push.)';
        }
        when .<html_url>:exists {
            say BOLD 'Pull request created at ' ~ .<html_url> ~ '.';
            return .<html_url>;
        }
    }
}

our sub github-get-issues($owner, $repo, :$closed) is export(:GIT) {
    temp $github-user = $github-token ?? $github-user ~ ':' ~ $github-token !! $github-user;
    my $state = $closed ?? '?state=all' !! '?state=open';
    my $github-response;

    loop (my $attempt = 1; $attempt ≤ 3; $attempt++) {
        my $curl = Proc::Async::Timeout.new('curl', '--silent', '-u', $github-user, '-X', 'GET', „https://api.github.com/repos/$owner/$repo/issues$state“);
        $curl.stdout.tap: { $github-response ~= .Str };

        await $curl.start: :timeout(%cfg<github><issues><timeout>.Int);

        CATCH {
            when X::Proc::Async::Timeout { 
                note RED ($attempt < 3) ?? "Github timed out, trying again $attempt/3." !! "Github timed out, giving up.";
                next if $attempt < 3;
                last;
            }
        }
        last
    }

    fail 'No response from Github' unless $github-response;

    given from-json($github-response).flat.cache {
        when .<message>:exists {
            fail RED .<message>;
        }
        when .[0].<title>:exists {
            return .item;
        }
        when () {
            return ();
        }
    }
}

our sub github-create-release($owner, $repo, $tag) is export(:GIT) {
    temp $github-user = $github-token ?? $github-user ~ ':' ~ $github-token !! $github-user;
    
    my $curl = Proc::Async::Timeout.new('curl', '--silent', '--user', $github-user, '--request', 'POST', '--data', to-json({ tag_name => $tag }), „https://api.github.com/repos/$owner/$repo/releases“);
    my $github-response;
    $curl.stdout.tap: { $github-response ~= .Str };

    say BOLD "Creating release $tag.";
    await $curl.start(:$timeout);

    given from-json($github-response) {
        when .<message>:exists {
            fail RED .<message>;
        }
        when .<tarball_url>:exists {
            say BOLD 'Tarball created at ⟨' ~ .<html_url> ~ '⟩.';
            return .<html_url>;
        }
    }

}

our sub git-push($base-dir, :$verbose) is export(:GIT) {
    my Promise $p;
    my $protocol = %cfg<git><protocol>;

    my $git = Proc::Async.new('git', '-C', $base-dir, 'remote', 'add', 'origin', "$protocol://github.com/$github-user/$base-dir");
    $git.stdout.tap: { Nil } unless $verbose;
    my $timeout = Promise.at(now + $git-timeout);
    
    await Promise.anyof($p = $git.start, $timeout);
    fail RED "⟨git remote⟩ timed out." if $p.status == Broken;
    
    say BOLD "Pushing repo to github.";
    $git = Proc::Async.new('git', '-C', $base-dir, 'push', 'origin', 'master');
    $git.stdout.tap: { Nil } unless $verbose;
    $timeout = Promise.at(now + $git-timeout);
    
    await Promise.anyof($p = $git.start, $timeout);
    fail RED "⟨git push⟩ timed out." if $p.status == Broken;
}

our sub git-clone($repo-url, :$verbose) is export(:GIT) {
    my $protocol = %cfg<git><protocol>;
    my Str $git-response;

    say BOLD "Cloning repo ⟨$repo-url⟩ to FS.";
    my $git = Proc::Async::Timeout.new('git', 'clone', $repo-url);
    $git.stderr.tap: { $git-response ~= .Str };
    
    await $git.start: :$timeout;
    $git-response.lines.grep(*.starts-with('Cloning into')).first.split("'")[1]
}

our sub git-add($file-path, :$base-dir, :$verbose) is export(:GIT) {
    my Str $git-response;

    say BOLD "Adding ⟨$base-dir/$file-path⟩ to local git repo.";
    my $git = Proc::Async::Timeout.new('git', 'add', '-v', $file-path);
    $git.stdout.tap: { $git-response ~= .Str };
    
    await $git.start(timeout => $git-timeout, cwd => $*CWD.child($base-dir));
    $git-response.lines.grep(*.starts-with('add ')).first.split("'")[1]
}

our sub git-commit(@files, $message, :$base-dir, :$verbose) is export(:GIT) {
    my Str $git-response;

    my $display-name = ('⟨' ~ $base-dir «~« '/' «~« @files »~» '⟩').join(', ');
    say BOLD "Commiting $display-name to local git repo.";
    my $git = Proc::Async::Timeout.new('git', 'commit', '-m', $message, |@files);
    $git.stdout.tap: { $git-response ~= .Str };
    
    await $git.start(timeout => $git-timeout, cwd => $*CWD.child($base-dir));
}

our sub git-log(:$base-dir) is export(:GIT) {
    my Str $git-response;

    my $git = Proc::Async::Timeout.new('git', 'log', '--pretty=oneline');
    $git.stdout.tap: { $git-response ~= .Str };
    
    await $git.start(timeout => $git-timeout, cwd => $*CWD.child($base-dir));
    
    $git-response.lines».substr(41)
}

our sub git-tag($version, :$base-dir, :$verbose) is export(:GIT) {
    my Str $git-response;

    my $git = Proc::Async.new('git', 'tag', '-a', $version, '-m', "Release as $version.");
    $git.stdout.tap: { $git-response ~= .Str };
    
    my $p = await $git.start(cwd => $*CWD.child($base-dir));
    die RED „git tag failed for $version.“ if $p.exitcode;
}

our sub git-push-tag($version, :$base-dir, :$verbose) is export(:GIT) {
    my $git = Proc::Async.new('git', '-C', $base-dir, 'push', 'origin', $version);
    $git.stdout.tap: { Nil } unless $verbose;
    my $timeout = Promise.at(now + $git-timeout);
    
    await Promise.anyof(my $p = $git.start, $timeout);
    fail RED "⟨git push⟩ timed out." if $timeout.status == Kept;
    die RED „git push tag failed for $version.“ if $p.result.exitcode;
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
        await Proc::Async::Timeout.new(.Str, $base-dir.IO.absolute).start: :$timeout;
    }
}

our sub post-create-hook($base-dir) is export(:HOOK) {
    for $cfg-dir.child('post-create.d').dir.grep(!*.ends-with('~')).sort {
        await Proc::Async::Timeout.new(.Str, $base-dir.IO.absolute).start: :$timeout;
    }
}

our sub post-push-hook($base-dir) is export(:HOOK) {
    for $cfg-dir.child('post-push.d').dir.grep(!*.ends-with('~')).sort {
        await Proc::Async::Timeout.new(.Str, $base-dir.IO.absolute).start: :$timeout;
    }
}

our proto sub read-cfg(|) is export(:HELPER) {*}

multi sub read-cfg(IO::Path:D $path) {
    use Slippy::Semilist;

    return unless $path.IO.e;

    my %h;
    slurp($path).lines\
        ».chomp\
        .grep(!*.starts-with('#'))\
        .grep(*.chars)\
        ».split(/\s* '=' \s*/)\
        .flat.map(-> $k, $v { %h{||$k.split('.').cache} = $v });
    
    %h
}

multi sub read-cfg(Mu:U $path) {
    my %h;
    %h<general><timeout> = 60;
    %h<check><disable-url-check> = 0; 
    %h<create><prefix> = 'raku-';
    %h<git><timeout> = 60;
    %h<git><protocol> = 'https';
    %h<github><issues><timeout> = 30;
    
    %h
}

multi sub read-meta6(IO::Path $path = './META6.json'.IO --> META6:D) is export(:HELPER) {
    META6.new(file => $path) or fail RED "Failed to process ⟨$path⟩."
}

our sub fetch-ecosystem(:$verbose, :$cached) is export(:HELPER) {
    state $cache;
    return $cache.Slip if $cached && $cache.defined;

    my $p6c-org = Proc::Async.new('curl', '--silent', 'https://raw.githubusercontent.com/ugexe/Perl6-ecosystems/master/p6c.json');
    my Promise $p1;
    my $p6c-response;
    $p6c-org.stdout.tap: { $p6c-response ~= .Str };

    my $cpan-org = Proc::Async.new('curl', '--silent', 'https://raw.githubusercontent.com/ugexe/Perl6-ecosystems/master/cpan.json');
    my Promise $p2;
    my $cpan-response;
    $cpan-org.stdout.tap: { $cpan-response ~= .Str };

    note BOLD "Fetching module list." if $verbose;
    await Promise.anyof(Promise.allof(($p1 = $p6c-org.start), ($p2 = $cpan-org.start)), Promise.at(now + $timeout));
    fail RED "⟨curl⟩ timed out." if $p1.status|$p2.status == Broken;
    
    note BOLD "Parsing module list." if $verbose;
    $cache = flat
        from-json($p6c-response).flat.cache,
        from-json($cpan-response).flat.cache;
    
    $cache.Slip
}

our sub query-module(Str $module-name, :$verbose) is export(:HELPER) {
    my @ecosystem = fetch-ecosystem(:$verbose, :cached);
    my $meta6 = @ecosystem.grep(*.<name> eq $module-name)[0] // Failure.new("Module ⟨$module-name⟩ not found in ecosystem.");
    my $module-url = $meta6<source-url> // $meta6<support><source> // Failure.new('No source url provided by ecosystem.');
    my ($owner, $repo) = $module-url.split('/')[3,4];

    return {:$owner, :$repo, :$meta6}
}

our sub local-module(:$verbose, :$base-dir = '.', :$meta6-file-name = 'META6.json') is export(:HELPER) {
    my IO::Path $meta6-file = ($base-dir ~ '/' ~ $meta6-file-name).IO;
    die RED "Can not find ⟨$meta6-file⟩." unless $meta6-file.e;
    my $meta6 = META6.new(file => $meta6-file) or die RED "Failed to process ⟨$meta6-file⟩.";
    my $module-url = $meta6<source-url> // $meta6<support>.source;
    my ($owner, $repo) = $module-url.split('/')[3,4];

    return {:$owner, :$repo, :$meta6}
}

our sub query-deps(Str $module-name?, :$base-dir = '.', :$meta6-file-name = 'META6.json', :$verbose) is export(:HELPER) {
    state %seen-modules;

    return $module-name if %seen-modules{$module-name}:exists;
    quietly %seen-modules{$module-name}++;
    
    my ($owner, $repo, $meta6) = ($module-name ?? try query-module($module-name, :$verbose) !! local-module(:$base-dir, :$meta6-file-name, :$verbose))<owner repo meta6>;

    my @deps;

    return $module-name unless $meta6<depends> ~~ Positional;
    
    for $meta6<depends>.flat {
        my $name = .split(':ver')[0];
        @deps.append: $name;
        @deps.append: query-deps($name, :$base-dir, :$meta6-file-name, :$verbose);
    }

    @deps.unique.cache
}
