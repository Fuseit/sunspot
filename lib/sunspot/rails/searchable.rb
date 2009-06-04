module Sunspot #:nodoc:
  module Rails #:nodoc:
    # 
    # This module adds Sunspot functionality to ActiveRecord models. As well as
    # providing class and instance methods, it optionally adds lifecycle hooks
    # to automatically add and remove models from the Solr index as they are
    # created and destroyed.
    #
    module Searchable
      class <<self
        def included(base) #:nodoc:
          base.module_eval { extend(ActsAsMethods) }
        end
      end

      module ActsAsMethods
        # 
        # Makes a class searchable if it is not already, or adds search
        # configuration if it is. Note that the options passed in are only used
        # the first time this method is called for a particular class; so,
        # search should be defined before activating any mixins that extend
        # search configuration.
        #
        # The block passed into this method is evaluated by the
        # <code>Sunspot.setup</code> method. See the Sunspot documentation for
        # complete information on the functionality provided by that method.
        #
        # ==== Options (+options+)
        # 
        # :auto_index<Boolean>::
        #   Automatically index models in Solr when they are saved.
        #   Default: true
        # :auto_remove<Boolean>::
        #   Automatically remove models from the Solr index when they are
        #   destroyed. <b>Setting this option to +false+ is not recommended
        #   </b>(see the README).
        #
        # ==== Example
        #
        #   class Post < ActiveRecord::Base
        #     searchable do
        #       text :title, :body
        #       string :sort_title do
        #         title.downcase.sub(/^(an?|the)/, '')
        #       end
        #       integer :blog_id
        #       time :updated_at
        #     end
        #   end
        #
        def searchable(options = {}, &block)
          Sunspot.setup(self, &block)

          unless searchable?
            extend ClassMethods
            include InstanceMethods

            unless options[:auto_index] == false
              after_save do |searchable|
                searchable.index
              end
            end

            unless options[:auto_remove] == false
              after_destroy do |searchable|
                searchable.remove_from_index
              end
            end
          end
        end

        # 
        # This method is defined on all ActiveRecord::Base subclasses. It
        # is false for classes on which #searchable has not been called, and
        # true for classes on which #searchable has been called.
        #
        # ==== Returns
        #
        # +false+
        #
        def searchable?
          false
        end
      end

      module ClassMethods
        # 
        # Search for instances of this class in Solr. The block is delegated to
        # the Sunspot.search method - see the Sunspot documentation for the full
        # API.
        #
        # ==== Example
        #
        #   Post.search do
        #     keywords 'best pizza'
        #     with :blog_id, 1
        #     order :updated_at, :desc
        #     facet :category_ids
        #   end
        #
        #
        # ==== Returns
        #
        # Sunspot::Search:: Object containing results, totals, facets, etc.
        #
        def search(&block)
          Sunspot.search(self, &block)
        end

        # 
        # Get IDs of matching results without loading the result objects from
        # the database. This method may be useful if search is used as an
        # intermediate step in a larger find operation. The block is the same
        # as the block provided to the #search method.
        #
        # ==== Returns
        #
        # Array:: Array of IDs, in the order returned by the search
        #
        def search_ids(&block)
          search(&block).raw_results.map { |raw_result| raw_result.primary_key.to_i }
        end

        # 
        # Remove instances of this class from the Solr index.
        #
        def remove_all_from_index
          Sunspot.remove_all(self)
        end

        # 
        # Remove all instances of this class from the Solr index and immediately
        # commit.
        #
        #---
        # XXX Sunspot should implement remove_all!()
        #
        def remove_all_from_index!
          Sunspot.remove_all(self)
          Sunspot.commit
        end

        # 
        # Completely rebuild the index for this class. First removes all
        # instances from the index, then loads records and save them. The
        # +batch_size+ argument is passed, records will be retrieved from the
        # database in batches of that size (recommended for larger data sets).
        #
        # ==== Parameters
        #
        # batch_size<Integer>:: Batch size with which to load records. Passing
        #                       'nil' will skip batches.  Default is 500.
        # batch_commit<Boolean>:: Flag singaling if a commit should be done after
        #                         after each batch is indexed, default is 'true'
        #
        def reindex(batch_size = 500, batch_commit = true)
          remove_all_from_index
          unless batch_size
            Sunspot.index(all)
          else
            record_count = count(:order => primary_key)
            counter = 1
            offset = 0
            while(offset < record_count)
              benchmark batch_size, counter do
                Sunspot.index(all(:offset => offset, :limit => batch_size, :order => primary_key))
              end
              offset += batch_size
              counter += 1
              Sunspot.commit if batch_commit
            end
          end
          Sunspot.commit
        end

        # 
        # Return the IDs of records of this class that are indexed in Solr but
        # do not exist in the database. Under normal circumstances, this should
        # never happen, but this method is provided in case something goes
        # wrong. Usually you will want to rectify the situation by calling
        # #clean_index_orphans or #reindex
        # 
        # ==== Returns
        #
        # Array:: Collection of IDs that exist in Solr but not in the database
        def index_orphans
          indexed_ids = search_ids.to_set
          all(:select => 'id').each do |object|
            indexed_ids.delete(object.id)
          end
          indexed_ids.to_a
        end

        # 
        # Find IDs of records of this class that are indexed in Solr but do not
        # exist in the database, and remove them from Solr. Under normal
        # circumstances, this should not be necessary; this method is provided
        # in case something goes wrong.
        #
        def clean_index_orphans
          index_orphans.each do |id|
            new do |fake_instance|
              fake_instance.id = id
            end.remove_from_index
          end
        end

        # 
        # Classes that have been defined as searchable return +true+ for this
        # method.
        #
        # ==== Returns
        #
        # +true+
        #
        def searchable?
          true
        end
        
        protected
        
        # 
        # Does some logging for benchmarking indexing performance
        #
        def benchmark(batch_size, counter,  &block)
          start = Time.now
          logger.info("[#{Time.now}] Start Indexing")
          yield
          elapsed = Time.now-start
          logger.info("[#{Time.now}] Completed Indexing. Rows indexed #{counter * batch_size}. Rows/sec: #{batch_size/elapsed.to_f} (Elapsed: #{elapsed} sec.)")
        end
        
      end

      module InstanceMethods
        # 
        # Index the model in Solr. If the model is already indexed, it will be
        # updated. Using the defaults, you will usually not need to call this
        # method, as models are indexed automatically when they are created or
        # updated. If you have disabled automatic indexing (see
        # ClassMethods#searchable), this method allows you to manage indexing
        # manually.
        #
        def index
          Sunspot.index(self)
        end

        # 
        # Index the model in Solr and immediately commit. See #index
        #
        def index!
          Sunspot.index!(self)
        end
        
        # 
        # Remove the model from the Solr index. Using the defaults, this should
        # not be necessary, as models will automatically be removed from the
        # index when they are destroyed. If you disable automatic removal
        # (which is not recommended!), you can use this method to manage removal
        # manually.
        #
        def remove_from_index
          Sunspot.remove(self)
        end

        # 
        # Remove the model from the Solr index and commit immediately. See
        # #remove_from_index
        #
        #---
        #FIXME Sunspot should implement remove!()
        #
        def remove_from_index!
          Sunspot.remove(self)
          Sunspot.commit
        end
      end
    end
  end
end
