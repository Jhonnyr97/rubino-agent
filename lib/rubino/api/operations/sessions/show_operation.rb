# frozen_string_literal: true

require "json"

module Rubino
  module API
    module Operations
      module Sessions
        # GET /v1/sessions/:id
        # Returns the session with its message timeline inlined.
        #
        # @raise [Rubino::NotFoundError] when the session does not exist.
        class ShowOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate repository and message store for tests.
          def initialize(repository: nil, message_store: nil)
            @repository = repository || ::Rubino::Session::Repository.new
            @message_store = message_store || ::Rubino::Session::Store.new
          end

          def call(request)
            id = request.params.fetch("id")
            session = @repository.find(id)
            raise NotFoundError.new("session", id) unless session

            [200, serialize(session)]
          end

          private

          def serialize(session)
            {
              id: session[:id],
              title: session[:title],
              instructions: nil,
              created_at: session[:created_at],
              status: session[:status],
              messages: messages_for(session[:id])
            }
          end

          def messages_for(session_id)
            @message_store.for_session(session_id).map do |m|
              {
                id: m.id,
                role: m.role,
                content: m.content,
                created_at: m.created_at
              }
            end
          end
        end
      end
    end
  end
end
