class ReleasesController < ApplicationController
  GITHUB_API_URL = "https://api.github.com/repos/kairan-app/feeeed/releases"

  def index
    @releases = fetch_releases

    respond_to do |format|
      format.atom
    end
  end

  private

  def fetch_releases
    response = Faraday.get(GITHUB_API_URL) do |req|
      req.headers["Accept"] = "application/vnd.github+json"
      req.headers["User-Agent"] = "rururu"
    end

    return [] unless response.success?

    JSON.parse(response.body)
  end
end
