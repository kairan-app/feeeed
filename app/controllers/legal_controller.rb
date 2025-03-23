class LegalController < ApplicationController
  def terms
    @title = "Terms of Service"
  end

  def privacy
    @title = "Privacy Policy"
  end
end
