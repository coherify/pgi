FROM ruby:3.4-alpine

RUN apk add --no-cache build-base postgresql-dev postgresql-client

WORKDIR /app

COPY Gemfile Gemfile.lock pgi.gemspec ./
COPY lib/pgi/version.rb ./lib/pgi/
RUN bundle install

COPY . .

CMD ["bundle", "exec", "rake", "test"]
