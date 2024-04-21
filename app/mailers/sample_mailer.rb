class SampleMailer < ApplicationMailer
  def hello(user)
    @user = user
    mail(to: @user.email, subject: "From SampleMailer!")
  end
end
