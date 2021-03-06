# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Admin::GroupsController do
  fab!(:admin) { Fabricate(:admin) }
  fab!(:user) { Fabricate(:user) }
  fab!(:group) { Fabricate(:group) }

  before do
    sign_in(admin)
  end

  describe '#create' do
    let(:group_params) do
      {
        group: {
          name: 'testing',
          usernames: [admin.username, user.username].join(","),
          owner_usernames: [user.username].join(","),
          allow_membership_requests: true,
          membership_request_template: 'Testing',
          members_visibility_level: Group.visibility_levels[:staff]
        }
      }
    end

    it 'should work' do
      post "/admin/groups.json", params: group_params

      expect(response.status).to eq(200)

      group = Group.last

      expect(group.name).to eq('testing')
      expect(group.users).to contain_exactly(admin, user)
      expect(group.allow_membership_requests).to eq(true)
      expect(group.membership_request_template).to eq('Testing')
      expect(group.members_visibility_level).to eq(Group.visibility_levels[:staff])
    end

    context "custom_fields" do
      before do
        plugin = Plugin::Instance.new
        plugin.register_editable_group_custom_field :test
      end

      after do
        DiscoursePluginRegistry.reset!
      end

      it "only updates allowed user fields" do
        params = group_params
        params[:group].merge!(custom_fields: { test: :hello1, test2: :hello2 })

        post "/admin/groups.json", params: params

        group = Group.last

        expect(response.status).to eq(200)
        expect(group.custom_fields['test']).to eq('hello1')
        expect(group.custom_fields['test2']).to be_blank
      end

      it "is secure when there are no registered editable fields" do
        DiscoursePluginRegistry.reset!
        params = group_params
        params[:group].merge!(custom_fields: { test: :hello1, test2: :hello2 })

        post "/admin/groups.json", params: params

        group = Group.last

        expect(response.status).to eq(200)
        expect(group.custom_fields['test']).to be_blank
        expect(group.custom_fields['test2']).to be_blank
      end
    end
  end

  describe '#add_owners' do
    it 'should work' do
      put "/admin/groups/#{group.id}/owners.json", params: {
        group: {
          usernames: [user.username, admin.username].join(",")
        }
      }

      expect(response.status).to eq(200)

      response_body = response.parsed_body

      expect(response_body["usernames"]).to contain_exactly(user.username, admin.username)

      expect(group.group_users.where(owner: true).map(&:user))
        .to contain_exactly(user, admin)
    end

    it 'returns not-found error when there is no group' do
      group.destroy!

      put "/admin/groups/#{group.id}/owners.json", params: {
        group: {
          usernames: user.username
        }
      }

      expect(response.status).to eq(404)
    end

    it 'does not allow adding owners to an automatic group' do
      group.update!(automatic: true)

      expect do
        put "/admin/groups/#{group.id}/owners.json", params: {
          group: {
            usernames: user.username
          }
        }
      end.to_not change { group.group_users.count }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(["You cannot modify an automatic group"])
    end

    it 'does not notify users when the param is not present' do
      put "/admin/groups/#{group.id}/owners.json", params: {
        group: {
          usernames: user.username
        }
      }
      expect(response.status).to eq(200)

      topic = Topic.find_by(title: "You have been added as an owner of the #{group.name} group", archetype: "private_message")
      expect(topic.nil?).to eq(true)
    end

    it 'notifies users when the param is present' do
      put "/admin/groups/#{group.id}/owners.json", params: {
        group: {
          usernames: user.username,
          notify_users: true
        }
      }
      expect(response.status).to eq(200)

      topic = Topic.find_by(title: "You have been added as an owner of the #{group.name} group", archetype: "private_message")
      expect(topic.nil?).to eq(false)
      expect(topic.topic_users.map(&:user_id)).to include(-1, user.id)
    end
  end

  describe '#remove_owner' do
    it 'should work' do
      group.add_owner(user)

      delete "/admin/groups/#{group.id}/owners.json", params: {
        user_id: user.id
      }

      expect(response.status).to eq(200)
      expect(group.group_users.where(owner: true)).to eq([])
    end

    it 'returns not-found error when there is no group' do
      group.destroy!

      delete "/admin/groups/#{group.id}/owners.json", params: {
        user_id: user.id
      }

      expect(response.status).to eq(404)
    end

    it 'does not allow removing owners from an automatic group' do
      group.update!(automatic: true)

      delete "/admin/groups/#{group.id}/owners.json", params: {
        user_id: user.id
      }

      expect(response.status).to eq(422)
      expect(response.parsed_body["errors"]).to eq(["You cannot modify an automatic group"])
    end
  end

  describe "#bulk_perform" do
    fab!(:group) do
      Fabricate(:group,
        name: "test",
        primary_group: true,
        title: 'WAT',
        grant_trust_level: 3
      )
    end

    fab!(:user) { Fabricate(:user, trust_level: 2) }
    fab!(:user2) { Fabricate(:user, trust_level: 4) }

    it "can assign users to a group by email or username" do
      Jobs.run_immediately!

      put "/admin/groups/bulk.json", params: {
        group_id: group.id, users: [user.username.upcase, user2.email, 'doesnt_exist']
      }

      expect(response.status).to eq(200)

      user.reload
      expect(user.primary_group).to eq(group)
      expect(user.title).to eq("WAT")
      expect(user.trust_level).to eq(3)

      user2.reload
      expect(user2.primary_group).to eq(group)
      expect(user2.title).to eq("WAT")
      expect(user2.trust_level).to eq(4)

      json = response.parsed_body
      expect(json['message']).to eq("2 users have been added to the group.")
      expect(json['users_not_added'][0]).to eq("doesnt_exist")
    end
  end

  context "#destroy" do
    it 'should return the right response for an invalid group_id' do
      max_id = Group.maximum(:id).to_i
      delete "/admin/groups/#{max_id + 1}.json"
      expect(response.status).to eq(404)
    end

    describe 'when group is automatic' do
      it "returns the right response" do
        group.update!(automatic: true)

        delete "/admin/groups/#{group.id}.json"

        expect(response.status).to eq(422)
        expect(Group.find(group.id)).to eq(group)
      end
    end

    describe 'for a non automatic group' do
      it "returns the right response" do
        delete "/admin/groups/#{group.id}.json"

        expect(response.status).to eq(200)
        expect(Group.find_by(id: group.id)).to eq(nil)
      end
    end
  end

  describe '#automatic_membership_count' do
    it 'returns count of users whose emails match the domain' do
      Fabricate(:user, email: 'user1@somedomain.org')
      Fabricate(:user, email: 'user1@somedomain.com')
      Fabricate(:user, email: 'user1@notsomedomain.com')
      group = Fabricate(:group)

      put "/admin/groups/automatic_membership_count.json", params: {
        automatic_membership_email_domains: 'somedomain.org|somedomain.com',
        id: group.id
      }
      expect(response.status).to eq(200)
      expect(response.parsed_body["user_count"]).to eq(2)
    end

    it "doesn't responde with 500 if domain is invalid" do
      group = Fabricate(:group)

      put "/admin/groups/automatic_membership_count.json", params: {
        automatic_membership_email_domains: '@somedomain.org|@somedomain.com',
        id: group.id
      }
      expect(response.status).to eq(200)
      expect(response.parsed_body["user_count"]).to eq(0)
    end
  end
end
