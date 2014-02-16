# -*- encoding : utf-8 -*-

require 'helpscout'
require 'httparty'
require 'mysql2'
require 'base64'
require 'json'
require 'find'

class OSTConverter
  def initialize(key = '74c67bff2eb4e40e391be29b68068713523ccd5c',
      dbhost = 'peter.avalonia.dk', dbuser = 'avalonia-user', dbpass = 'ADZXXpVNXLs68teJdGhw', db = 'crm')

    @api_key = key
    @auth = {username: @api_key, password: 'X'}
    @dbhost = dbhost
    @dbuser = dbuser
    @dbpass = dbpass
    @db = db
    @hsclient = HelpScout::Client.new(@api_key)
    @mailbox_id = get_mailbox_id
    @attachments_dir = 'osTicketFiles'
    @url = 'https://api.helpscout.net/v1/conversations.json'
    @con = create_mysql_connection
    @tickets = get_tickets
    create_tickets
    #create_demo
  end

  def create_demo
    thread = {
        type: 'customer',
        createdBy: {
            email: 'hr.noergaard@icloud.com',
            type: 'customer'
        },
        body: 'Hjææææælp',
        attachments: send_attachments(['osTicketFiles/0111/1D9CC0899B5A370_emailgreen.jpg', 'osTicketFiles/0111/7B0A6A98C109D80_music_728x90.jpg'])
    }
    conversation = {
        customer: {
            email: 'hr.noergaard@icloud.com',
            type: 'customer'
        },
        subject: 'TEST!!!!',
        mailbox: {
            id: @mailbox_id
        },
        threads: [thread]
    }

    begin
      response = HTTParty.post(@url, {
          basic_auth: @auth,
          headers: {'Content-Type' => 'application/json', 'imported' => 'true'},
          body: conversation.to_json
      })
    rescue SocketError => se
      raise StandardError, se.message
    end

    if response.code == 201
      if response["item"]
        response["item"]
      else
        response["Location"]
      end
    else
      raise StandardError.new("Server Response: #{response.code} #{response.message} #{response.body}")
    end
  end

  def create_tickets
    @tickets.each do |row|
      create_ticket row
    end
  end

  def create_ticket(row)
    t_id = row['ticket_id']
    t_email = row['email']
    t_subject = row['subject']
    t_status = row['status'].eql?('open') ? 'active' : 'closed'
    t_created = row['created'].iso8601(0)

    messages = get_messages(t_id)
    responses = get_responses(t_id)
    notes = get_notes(t_id)

    threads = []

    messages.each do |message|
      temphash = {
          type: 'customer',
          createdBy: {
              email: t_email,
              type: 'customer'
          },
          body: message['message'],
          status: t_status,
          createdAt: message['created'].iso8601(0)
      }
      attachments = get_attachments(message['msg_id'], 'M')
      files = get_attached_files(attachments)
      unless files.empty?
        temphash[:attachments] = send_attachments(files)
      end
      threads << temphash
    end

    conversation = {
        customer: {
            email: t_email,
            type: 'customer'
        },
        subject: t_subject,
        mailbox: {
            id: @mailbox_id
        },
        status: t_status,
        createdAt: t_created,
        threads: threads
    }

    begin
      response = HTTParty.post(@url, {
          basic_auth: @auth,
          headers: {'Content-Type' => 'application/json', 'imported' => 'true'},
          body: conversation.to_json
      })
    rescue SocketError => se
      raise StandardError, se.message
    end

    if response.code == 201
      location = response["Location"]
    else
      raise StandardError.new("Server Response during tid'#{t_id}': #{response.code} #{response.message} #{response.body}")
    end

    responses.each do |res|
      body = res['response'].eql?(' ') || res['response'].empty? ? 'Empty body' : res['response']
      temphash = {
          type: 'message',
          createdBy: {
              id: get_user_id_from_email(res['email']),
              type: 'user'
          },
          body: body,
          status: t_status,
          createdAt: res['created'].iso8601(0)
      }
      attachments = get_attachments(res['response_id'], 'R')
      files = get_attached_files(attachments)
      unless files.empty?
        temphash[:attachments] = send_attachments(files)
      end

      begin
        response = HTTParty.post(location, {
            basic_auth: @auth,
            headers: {'Content-Type' => 'application/json', 'imported' => 'true'},
            body: temphash.to_json
        })
      rescue SocketError => se
        raise StandardError, se.message
      end

      unless response.code == 201
        raise StandardError.new("Server Response during tid'#{t_id}': #{response.code} #{response.message} #{response.body}")
      end
    end

    notes.each do |note|
      temphash = {
          type: 'note',
          createdBy: {
              id: get_user_id_from_email(note['email']),
              type: 'user'
          },
          body: note['title']+"\r\n\r\n"+note['note'],
          status: t_status,
          createdAt: note['created'].iso8601(0)
      }

      begin
        response = HTTParty.post(location, {
            basic_auth: @auth,
            headers: {'Content-Type' => 'application/json', 'imported' => 'true'},
            body: temphash.to_json
        })
      rescue SocketError => se
        raise StandardError, se.message
      end

      unless response.code == 201
        raise StandardError.new("Server Response during tid'#{t_id}': #{response.code} #{response.message} #{response.body}")
      end
    end

  end

  def get_user_id_from_email(email)
    users = @hsclient.users
    user = nil
    users.each do |u|
      user = u if u.email.eql?(email)
    end
    user.id
  end

  def send_attachments(files)
    attachments = []
    files.each do |file|

      data = nil
      File.open(file, 'r') do |f|
        data = Base64.encode64(f.read)
      end

      req = {
          fileName: File.basename(file),
          mimeType: 'text/plain',
          data: data
      }

      begin
        response = HTTParty.post('https://api.helpscout.net/v1/attachments.json', {
            basic_auth: @auth,
            headers: {'Content-Type' => 'application/json'},
            body: req.to_json
        })
      rescue SocketError => se
        raise StandardError, se.message
      end

      if response.code == 201
        res = JSON.parse(response.body)
        attachments << res['item']
      else
        raise StandardError.new("Server Response: #{response.code} #{response.message} #{response.body}")
      end
    end
    attachments
  end

  def get_attached_files(attachments)
    files = []
    attachments.each do |row|
      files.concat Dir.glob("osTicketFiles/**/#{row['file_key']}*")
    end
    files
  end

  def get_attachments(id, ref_t)
    @con.query "SELECT file_name, file_key FROM ost_ticket_attachment WHERE ref_id=#{id} AND ref_type='#{ref_t}';"
  end

  def get_notes(t_id)
    @con.query 'SELECT title, note, ost_ticket_note.created, email '+
        'FROM ost_ticket_note INNER JOIN ost_staff ON ost_ticket_note.staff_id = ost_staff.staff_id '+
        "WHERE ticket_id=#{t_id} AND source <> 'system' ORDER BY created;"
  end

  def get_responses(t_id)
    @con.query 'SELECT response_id, response, ost_ticket_response.created, email ' +
        'FROM ost_ticket_response INNER JOIN ost_staff ON ost_ticket_response.staff_id = ost_staff.staff_id '+
                   "WHERE ticket_id=#{t_id} ORDER BY created;"
  end

  def get_messages(t_id)
    @con.query "SELECT msg_id, message, created FROM ost_ticket_message WHERE ticket_id=#{t_id} ORDER BY created;"
  end

  def get_tickets
    @con.query 'SELECT ticket_id, email, subject, status, created '+
                   'FROM ost_ticket WHERE ticket_id>3257 ORDER BY ticket_id;'
  end

  def create_mysql_connection
    begin
      Mysql2::Client.new({host: @dbhost, username: @dbuser, password: @dbpass, database: @db})
    rescue Mysql2::Error => e
      raise StandardError, e.message
    end
  end

  def get_mailbox_id
    mailboxes = @hsclient.mailboxes
    puts '-- Mailboxes --'
    mailboxids = []
    mailboxes.each do |mb|
      puts "Name: #{mb.name}, ID: #{mb.id}"
      mailboxids << mb.id
    end
    printf 'Please enter the ID of the mailbox you want to import to: '

    id = gets.to_i
    until mailboxids.include? id
      printf 'Invalid id. Please try again: '
      id = gets.to_i
    end
    id
  end
end

OSTConverter.new
