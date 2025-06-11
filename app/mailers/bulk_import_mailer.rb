class BulkImportMailer < ApplicationMailer
  def result_notification(user, results)
    @user = user
    @results = results

    subject = "フィード一括登録結果: 成功#{results[:success].size}件"

    mail(
      to: user.email,
      subject: subject
    )
  end
end
