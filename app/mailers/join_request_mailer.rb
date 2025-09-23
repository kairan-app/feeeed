class JoinRequestMailer < ApplicationMailer
  def welcome_email(join_request)
    @join_request = join_request
    @login_url = root_url

    mail(
      to: @join_request.email,
      subject: "rururuへようこそ！アクセスが承認されました 🎉"
    )
  end
end
