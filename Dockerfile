# syntax = docker/dockerfile:1

FROM ruby:4.0.5

RUN apt-get update -qq && apt-get install -y nodejs postgresql-client libvips-dev

RUN mkdir /app
WORKDIR /app

COPY Gemfile /app/Gemfile
COPY Gemfile.lock /app/Gemfile.lock

RUN gem update --system 4.0.12 --no-document && \
    gem install bundler -v 4.0.12 --no-document
RUN bundle install

COPY . /app

ENTRYPOINT ["/app/bin/docker-entrypoint"]
CMD ["./bin/rails", "server"]
