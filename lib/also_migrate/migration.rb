module AlsoMigrate
  module Migration

    def self.included(base)
      unless base.respond_to?(:method_missing_with_also_migrate)
        base.extend MigrateMethods
        base.class_eval do
          class << self
            alias_method :method_missing_without_also_migrate, :method_missing
            alias_method :method_missing, :method_missing_with_also_migrate
          end
          include MigrateMethods
          alias_method :method_missing_without_also_migrate, :method_missing
          alias_method :method_missing, :method_missing_with_also_migrate
        end
      end
    end

    module MigrateMethods

      def method_missing_with_also_migrate(method, *arguments, &block)
        supported = [
          :add_column, :add_index, :add_timestamps, :change_column,
          :change_column_default, :change_table, :create_table,
          :drop_table, :remove_column, :remove_columns,
          :remove_timestamps, :rename_column, :rename_table
        ]

        args = Marshal.load(Marshal.dump(arguments)) if supported.include?(method)
        return_value = self.method_missing_without_also_migrate(method, *arguments, &block)

        # Rails reversible migrations are implemented by substituing a CommandRecorder
        # object in place of the actual database connection. To ensure compatibility with
        # the reversible migrations, we skip performing any actions during the 'up' part of the
        # migration to allow the CommandRecorder to record the up version of changes to the source
        # table. When the inverse operations are later replayed against the actual database connection,
        # we will then allow the method_missing hooks to fire and generate corresponding changes for the
        # 'down' part of the migration.
        return if @connection.is_a?(ActiveRecord::Migration::CommandRecorder)

        if args && !args.empty? && supported.include?(method)
          connection = (@connection || ActiveRecord::Base.connection)
          table_name = if ActiveRecord.version < Gem::Version.new("4.1")
                         ActiveRecord::Migrator.proper_table_name(args[0])
                       else
                         ActiveRecord::Migration.proper_table_name(args[0])
                       end

          # Find models
          (::AlsoMigrate.configuration || []).each do |config|
            next unless config[:source].to_s == table_name

            # Don't change ignored columns
            [ config[:ignore] ].flatten.compact.each do |column|
              next if args.include?(column) || args.include?(column.intern)
            end

            # Run migration
            if method == :create_table
              ActiveRecord::Migrator::AlsoMigrate.create_tables(config)
            elsif method == :add_index && !config[:indexes].nil?
              next
            else
              [ config[:destination] ].flatten.compact.each do |table|
                if connection.try(:table_exists?, table)
                  args[0] = table
                  begin
                    connection.send(method, *args, &block)
                  rescue Exception => e
                    puts "(also_migrate warning) #{e.message}"
                  end
                end
              end
            end
          end
        end

        return return_value
      end
    end
  end
end
