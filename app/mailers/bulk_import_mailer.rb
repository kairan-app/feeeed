class BulkImportMailer < ApplicationMailer
  def result_notification(user, results)
    @user = user
    @results = results

    subject = "Bulk Feed Import Results: #{results[:success].size} successful"

    mail(
      to: user.email,
      subject: subject
    )
  end
end
