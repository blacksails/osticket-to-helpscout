# -*- encoding : utf-8 -*-

require 'helpscout'
require 'httparty'
require 'mysql2'
require 'base64'
require 'json'
require 'find'
require 'set'

class OSTConverter
  def initialize(key,
      dbhost, dbuser, dbpass, db)

    @api_key = key
    @auth = {username: @api_key, password: 'X'}
    @hsclient = HelpScout::Client.new(@api_key)
    @mailbox_id = get_mailbox_id
    @attachments_dir = 'osTicketFiles'
    @url = 'https://api.helpscout.net/v1/conversations.json'
    @con = create_mysql_connection(dbhost, dbuser, dbpass, db)
    @tickets = get_tickets
    @total = 0
    @num_tickets = @tickets.count
    create_tickets
    @con.close
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

    @total += 1
    puts "Now processing ticket##{t_id} #{@total}/#{@num_tickets}"

    messages = get_messages(t_id)
    responses = get_responses(t_id)
    notes = get_notes(t_id)

    message_rows = []
    response_rows = []
    note_rows =[]
    dates = Set.new
    date_type = {}
    messages.each do |mes|
      date = mes['created']
      dates << date
      if date_type[date].nil?
        date_type[date] = {}
      end
      if date_type[date][1].nil?
        date_type[date][1] = 1
      else
        date_type[date][1] += 1
      end
      message_rows << mes
    end
    responses.each do |res|
      date = res['created']
      dates << date
      if date_type[date].nil?
        date_type[date] = {}
      end
      if date_type[date][2].nil?
        date_type[date][2] = 1
      else
        date_type[date][2] += 1
      end
      response_rows << res
    end
    notes.each do |note|
      date = note['created']
      dates << date
      if date_type[date].nil?
        date_type[date] = {}
      end
      if date_type[date][3].nil?
        date_type[date][3] = 1
      else
        date_type[date][3] += 1
      end
      note_rows << note
    end
    dates = dates.to_a.sort!

    location = nil
    first_thread = true
    dates.each do |date|
      threads = []

      keys = date_type[date].keys.sort
      keys.each do |key|
        case key
          when 1
            date_type[date][1].times do
              thread = {}
              mes = message_rows.shift
              thread[:type] = 'customer'
              thread[:createdBy] = {
                  email: t_email,
                  type: 'customer'
              }
              body = mes['message'].eql?(' ') || mes['message'].empty? ? 'Empty body' : mes['message']
              thread[:body] = body
              thread[:status] = t_status
              thread[:createdAt] = mes['created'].iso8601(0)
              attachments = get_attachments(mes['msg_id'], 'M')
              files = get_attached_files attachments
              unless files.empty?
                thread[:attachments] = send_attachments files
              end
              threads << thread
            end
          when 2
            date_type[date][2].times do
              thread = {}
              res = response_rows.shift
              thread[:type] = 'message'
              thread[:createdBy] = {
                  id: get_user_id_from_email(res['email']),
                  type: 'user'
              }
              body = res['response'].eql?(' ') || res['response'].empty? ? 'Empty body' : res['response']
              thread[:body] = body
              thread[:status] = t_status
              thread[:createdAt] = res['created'].iso8601(0)
              attachments = get_attachments(res['response_id'], 'R')
              files = get_attached_files attachments
              unless files.empty?
                thread[:attachments] = send_attachments files
              end
              threads << thread
            end
          when 3
            date_type[date][3].times do
              thread = {}
              note = note_rows.shift
              thread[:type] = 'note'
              thread[:createdBy] = {
                  id: get_user_id_from_email(note['email']),
                  type: 'user'
              }
              thread[:body] = note['title']+"\r\n\r\n"+note['note']
              thread[:status] = t_status
              thread[:createdAt] = note['created'].iso8601(0)
              threads << thread
            end
          else
            puts 'COALA!'
        end
      end

      if first_thread
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
            threads: [
                threads.shift
            ]
        }

        begin
          response = HTTParty.post(@url, {
              basic_auth: @auth,
              headers: {'Content-Type' => 'application/json'},
              body: conversation.to_json,
              query: {imported: true}
          })
        rescue SocketError => se
          raise StandardError, se.message
        end

        if response.code == 201
          location = response["Location"]
        else
          raise StandardError.new("Server Response during tid'#{t_id}': #{response.code} #{response.message} #{response.body}")
        end

        first_thread = false
      else
        threads.each do |t|
          begin
            response = HTTParty.post(location, {
                basic_auth: @auth,
                headers: {'Content-Type' => 'application/json'},
                body: t.to_json,
                query: {imported: true}
            })
          rescue SocketError => se
            raise StandardError, se.message
          end

          unless response.code == 201
            raise StandardError.new("Server Response during tid'#{t_id}': #{response.code} #{response.message} #{response.body}")
          end
        end
      end
    end
  end

  def get_user_id_from_email(email)
    users = @hsclient.users
    user = nil
    users.each do |u|
      user = u if u.email.eql?(email)
    end
    unless user
      users.each do |u|
        user = u if u.email.eql?('jakob@backupbank.dk')
      end
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
                   'FROM ost_ticket ORDER BY ticket_id;'
  end

  def create_mysql_connection(dbhost, dbuser, dbpass, db)
    begin
      Mysql2::Client.new({host: dbhost, username: dbuser, password: dbpass, database: db})
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

OSTConverter.new('yourapikey','yourdbhost','yourdbuser','yourdbpass','yourdb')
