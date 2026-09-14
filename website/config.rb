activate :autoprefixer do |prefix|
  prefix.browsers = "last 2 versions"
end

configure :development do
  activate :livereload
  activate :directory_indexes
end

configure :build do
  activate :directory_indexes
end
