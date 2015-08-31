# -*- coding: utf-8 -*-

require 'json'
require 'net/http'

Plugin.create(:oasiz_datasource_lingr) do

  @lingr = nil
  @last_message_times = {}

  # 馬鹿にしか見えない行らしいですよ
  @app_key = 'd21aY2NI\n'.unpack('m')[0]

  settings("Lingr") do
      settings("基本設定(変更したら、mikutter を再起動してください)") do
          input("username", :oasiz_datasource_lingr_username)
          inputpass("password", :oasiz_datasource_lingr_password)
          input("app_key(空の場合、デフォルトの key を使用します)", :oasiz_datasource_lingr_app_key)
      end
      settings("Room 設定") do
          multi("Room ID", :oasiz_datasource_lingr_rooms)
      end
  end

  on_boot do |service|
      if UserConfig[:oasiz_datasource_lingr_username] &&
          UserConfig[:oasiz_datasource_lingr_password]

        unless UserConfig[:oasiz_datasource_lingr_app_key].empty?
          @app_key = UserConfig[:oasiz_datasource_lingr_app_key]
        end

        @lingr = Lingr.new(
            UserConfig[:oasiz_datasource_lingr_username],
            UserConfig[:oasiz_datasource_lingr_password],
            @app_key)
      end

      rooms = UserConfig[:oasiz_datasource_lingr_rooms]
      rooms = [] unless rooms
      for room in rooms
          @last_message_times[room] = '0000-00-00T00:00:00Z'
      end
  end

  # データソースへ登録
  filter_extract_datasources { |datasources|
    datasources[:oasiz_datasource_lingr] = "Lingr"

    [datasources]
  }

  # Lingr からメッセージを取得する
  on_period { |service|
    if service == Service.primary
      messages = []

      # 設定された Room 一覧を取得し、全 Room のメッセージを取得
      rooms = UserConfig[:oasiz_datasource_lingr_rooms]
      rooms = [] unless rooms
      for room in rooms
        @last_message_times[room] = '0000-00-00T00:00:00Z' unless @last_message_times[room]
        room_messages = @lingr.get_messages(room, @last_message_times[room])
        messages.concat(room_messages)
        @last_message_times[room] = room_messages.last['timestamp'] if room_messages.last
      end

      # timestamp 順にソート
      # mikutter の Message に変換
      mikutter_messages = messages.sort_by { |item| item['timestamp'] }
          .map { |item|
              # mikutter ユーザー情報作成
              user = User.new(:id => -5939, :idname => item['room'])
              user[:name] = item['nickname']
              user[:profile_image_url] = item['icon_url']

              # mikutter メッセージ情報作成
              message = Message.new(
                  :message => item['text'],
                  :system => true)
              time = Time.parse(item['timestamp'])
              message[:created] = time
              message[:modified] = time
              message[:user] = user
              message
          }

      Plugin.call(:extract_receive_message, :oasiz_datasource_lingr, mikutter_messages)
    end
  }
end


# Lingr クラス
class Lingr
    ENDPOINT_URL = 'http://lingr.com/api/'

    # コンストラクタ
    # ユーザー名、パスワードからセッションを作成する
    def initialize(username, password, app_key)
        @username = username
        @password = password
        @app_key = app_key
        @session = create_session(username, password, app_key)
    end

    # セッションを破棄する
    def close
        destroy_session
    end

    # メッセージを取得する
    # TODO: 文字列じゃなくて日付型もらいたいよね
    def get_messages(rooms, start_time = '0000-00-00T00:00:00Z')
        verify_session


        response = Net::HTTP.post_form(
            URI.parse(ENDPOINT_URL + 'room/show'), {'session'=>@session, 'rooms'=>rooms})
        json = JSON.parse(response.body)
        rooms = json['rooms'][0] if json['rooms']

        if rooms && rooms['messages']
          return rooms['messages'].select{ |item|
              item['timestamp'] > start_time
          }.sort_by{ |message|
              message['timestamp']
          }
        else
          return []
        end
    end

    def self.force_exit!
      @lingr.close
    end

    private

    # セッションを作成する
    def create_session(username, password, app_key)
        response = Net::HTTP.post_form(
            URI.parse(ENDPOINT_URL + 'session/create'), {'user'=>username, 'password'=>password, 'app_key'=>app_key})

        json = JSON.parse(response.body)

        if json['status'] != 'ok'
          raise "create session error"
        end

        return json['session']
    end

    # セッションを破棄する
    def destroy_session
        Net::HTTP.post_form(
            URI.parse(ENDPOINT_URL + 'session/destroy'), {'session'=>@session})
    end

    # セッションの有効性を確認し、必要であればアップデートする
    def verify_session
        response = Net::HTTP.post_form(
            URI.parse(ENDPOINT_URL + 'session/verify'), {'session'=>@session})

        json = JSON.parse(response.body)

        status = json['status']

        @session = create_session(@username, @password, @app_key) unless status == "ok"

    end
end
