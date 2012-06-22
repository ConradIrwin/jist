Jist is a gem that allows you to publish a [gist](https://gist.github.com) from Ruby.

# Introduction

Jist is a really simple library that wraps a single API call, you use it:

```ruby
Jist.gist("Look.at(:my => 'awesome').code")
```

If you need more advanced features you can also pass:

* `:username` and `:password` to log in and post an authenticated gist.
* `:filename` to change the syntax highlighting (default is `a.rb`).
* `:public` if you want your gist to have a guessable url.
* `:description` to add a description to your gist.

Todo
====

It'd be nice to add a binary so that you can use it from your terminal. In the meantime you can use:

```shell

$ ruby -rjist -e'puts Jist.gist(ARGF.read)["html_url"]' <<EOF
Look.at(:my => 'awesome').code
EOF
```

Meta-fu
=======

I wrote this because the `gist` gem is out of action, and has been for many months.

It's licensed under the MIT license, and bug-reports, and pull requests are welcome.
