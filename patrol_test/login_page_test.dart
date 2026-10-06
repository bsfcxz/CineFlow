/// 登录页真机 UI 测试。
///
/// ## 这个测试证明什么
///
/// 走的是**真实启动路径**：`ProviderScope + CineFlowApp`（与 main.dart 一致），
/// 因此覆盖了会话恢复 → 路由门控 → 登录页渲染 → 表单交互的完整链路。
/// 首次安装（Patrol 的 clearPackageData=true）没有会话，
/// `resolveRedirect` 必然把用户送到 `/login`——这是可确定复现的起点。
///
/// ## 为什么只测到"校验"就停
///
/// 真正的登录需要一台可用的 Emby 服务器与凭据，测试环境没有。
/// 而**校验分支**（三个字段没填全时的提示）不需要网络、结果确定，
/// 是这一屏最值得守的行为：它是用户第一次点"登录"时得到的反馈。
/// 填入假地址再提交会发起真实网络请求并长时间挂起，
/// 那种"测试时好时坏"的东西不能作为回归线。
///
/// ## 跑法
/// patrol test -t patrol_test/login_page_test.dart
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrol/patrol.dart';

import 'package:cineflow/keys.dart';
import 'package:cineflow/main.dart';

void main() {
  patrolTest(
    '登录页：未填字段时提交给出校验提示；密码可见性可切换',
    ($) async {
      await $.pumpWidgetAndSettle(const ProviderScope(child: CineFlowApp()));

      // 未登录 → 路由门控把用户送到登录页
      await $(keys.login.page).waitUntilVisible();

      // 三个字段都空着就点「登录」：必须给出明确提示，
      // 而不是静默无反应或直接发请求。
      await $(keys.login.submitButton).tap();
      await $('请完整填写服务器地址、用户名和密码').waitUntilVisible();

      // 填完整后，密码可见性切换必须真的改变输入框的 obscureText
      // （这是"眼睛图标没接线"这类缺陷唯一的断言点）
      await $(keys.login.serverField).enterText('http://127.0.0.1:9');
      await $(keys.login.usernameField).enterText('tester');
      await $(keys.login.passwordField).enterText('secret123');

      await $(keys.login.passwordToggle).tap();

      final passwordField = $(keys.login.passwordField).evaluate().single.widget
          as TextField;
      expect(
        passwordField.obscureText,
        isFalse,
        reason: '点了眼睛图标之后密码仍是遮蔽状态 —— 切换没接线',
      );

      // 「记住密码」默认勾选（登录页的既定默认），点一下应取消
      await $(keys.login.rememberRow).tap();
    },
  );
}
