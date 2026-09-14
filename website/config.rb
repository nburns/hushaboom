# GitHub Pages serves from /docs at the repository root, so the build lands
# outside this directory.
set :build_dir, File.expand_path('../docs', __dir__)

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
