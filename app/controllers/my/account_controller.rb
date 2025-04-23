module My
  class AccountController < ApplicationController
    def delete
    end

    def destroy
      current_user.destroy
      reset_session
      redirect_to root_path, notice: '退会が完了しました。ご利用ありがとうございました。'
    end
  end
end