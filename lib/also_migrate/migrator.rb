module AlsoMigrate
  module Migrator

    def self.included(base)
      unless base.included_modules.include?(InstanceMethods)
        base.send :include, InstanceMethods
        base.class_eval do
          alias_method :migrate_without_also_migrate, :migrate
          alias_method :migrate, :migrate_with_also_migrate
        end
      end
    end

    module InstanceMethods

      def migrate_with_also_migrate
        (::AlsoMigrate.configuration || []).each do |config|
          AlsoMigrate.create_tables(config)
        end
      rescue Exception => e
        puts "AlsoMigrate error: #{e.message}"
        puts e.backtrace.join("\n")
      ensure
        migrate_without_also_migrate
      end

      module AlsoMigrate
        class << self

          def write(text="")
            puts(text)
          end

          def say(message, subitem=false)
            write "#{subitem ? "   ->" : "--"} #{message}"
          end

          def say_with_time(message)
            say(message)
            result = nil
            time = Benchmark.measure { result = yield }
            say "%.4fs" % time.real, :subitem
            say("#{result} rows", :subitem) if result.is_a?(Integer)
            result
          end

          def connection
            ActiveRecord::Base.connection
          end

          def create_tables(config)
            [ config[:destination] ].flatten.compact.each do |new_table|
              if !connection.table_exists?(new_table) && connection.table_exists?(config[:source])
                columns = connection.columns(config[:source]).collect(&:name)
                columns -= [ config[:subtract] ].flatten.compact.collect(&:to_s)
                columns.collect! { |col| connection.quote_column_name(col) }
                if config[:indexes]
                  engine =
                    if connection.class.to_s.include?('Mysql')
                      'ENGINE=' + connection.select_one(<<-SQL)['Engine']
                        SHOW TABLE STATUS
                        WHERE Name = '#{config[:source]}'
                      SQL
                    end
                  say_with_time "create_table(#{new_table.inspect})" do
                    connection.execute(<<-SQL)
                      CREATE TABLE #{new_table} #{engine}
                      AS SELECT #{columns.join(',')}
                      FROM #{config[:source]}
                      WHERE false;
                    SQL
                  end
                  [ config[:indexes] ].flatten.compact.each do |column|
                    say_with_time "add_index(#{new_table.inspect}, #{column.inspect})" do
                      connection.add_index(new_table, column)
                    end
                  end
                else
                  if connection.class.to_s.include?('SQLite')
                    col_string = connection.columns(config[:source]).collect {|c|
                      "#{c.name} #{c.sql_type}"
                    }.join(', ')
                    say_with_time "create_table(#{new_table.inspect})" do
                      connection.execute(<<-SQL)
                        CREATE TABLE #{new_table}
                        (#{col_string})
                      SQL
                    end
                  else
                    say_with_time "create_table(#{new_table.inspect})" do
                      connection.execute(<<-SQL)
                        CREATE TABLE #{new_table}
                        LIKE #{config[:source]};
                      SQL
                    end
                  end
                end
              end
              if connection.table_exists?(new_table)
                if config[:add] || config[:subtract]
                  columns = connection.columns(new_table).collect(&:name)
                end
                if config[:add]
                  config[:add].each do |column|
                    unless columns.include?(column[0])
                      say_with_time "add_column(#{new_table.inspect}, #{column.inspect})" do
                        connection.add_column(*([ new_table ] + column))
                      end
                    end
                  end
                end
                if config[:subtract]
                  [ config[:subtract] ].flatten.compact.each do |column|
                    if columns.include?(column)
                      say_with_time "add_column(#{new_table.inspect}, #{column.inspect})" do
                        connection.remove_column(new_table, column)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
