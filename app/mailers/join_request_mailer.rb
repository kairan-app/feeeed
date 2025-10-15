class JoinRequestMailer < ApplicationMailer
  def welcome(join_request)
    @join_request = join_request
    @root_url = root_url
    @guides_url = guides_url

    mail(
      to: @join_request.email,
      subject: "rururuへ招待いたします🎉"
    )
  end
end
