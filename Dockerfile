# syntax = docker/dockerfile:1

FROM ruby:3.4.2

RUN apt-get update -qq && apt-get install -y nodejs postgresql-client

RUN mkdir /app
WORKDIR /app

COPY Gemfile /app/Gemfile
COPY Gemfile.lock /app/Gemfile.lock

RUN gem install bundler
RUN bundle install

COPY . /app

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["./bin/rails", "server"]
