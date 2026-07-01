// POSTERCHILD MEDIA — GOOGLE SHEETS CRM + EMAIL AUTOMATION
// Paste this into Google Apps Script after creating your Google Sheet.

const OWNER_EMAIL = 'amvlgam@gmail.com';
const BUSINESS_NAME = 'Posterchild Media';

function doPost(e) {
  try {
    const sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName('Leads') || SpreadsheetApp.getActiveSpreadsheet().insertSheet('Leads');
    const data = JSON.parse(e.postData.contents || '{}');

    const headers = [
      'Submitted At', 'First Name', 'Last Name', 'Email', 'Phone', 'Source',
      'Session Type', 'Preferred Date', 'Location', 'People', 'Video',
      'Investment Level', 'Prints Interest', 'Inspiration', 'Vision', 'Experience', 'Status'
    ];

    if (sheet.getLastRow() === 0) {
      sheet.appendRow(headers);
    }

    sheet.appendRow([
      new Date(), data.first_name || '', data.last_name || '', data.email || '', data.phone || '', data.source || '',
      data.session_type || '', data.preferred_date || '', data.location || '', data.people || '', data.video || '',
      data.investment_level || '', data.prints_interest || '', data.inspiration || '', data.vision || '', data.experience || '', 'New'
    ]);

    const clientName = `${data.first_name || ''} ${data.last_name || ''}`.trim();
    const ownerSubject = 'New Posterchild Media Booking Inquiry';
    const ownerBody = `New booking inquiry received.\n\nName: ${clientName}\nEmail: ${data.email || ''}\nPhone: ${data.phone || ''}\nSource: ${data.source || ''}\nSession Type: ${data.session_type || ''}\nPreferred Date: ${data.preferred_date || ''}\nLocation: ${data.location || ''}\nPeople: ${data.people || ''}\nVideo: ${data.video || ''}\nInvestment Level: ${data.investment_level || ''}\nPrints Interest: ${data.prints_interest || ''}\nInspiration: ${data.inspiration || ''}\n\nVision:\n${data.vision || ''}\n\nExperience Notes:\n${data.experience || ''}`;

    GmailApp.sendEmail(OWNER_EMAIL, ownerSubject, ownerBody, { name: BUSINESS_NAME });

    if (data.email) {
      GmailApp.sendEmail(
        data.email,
        'We received your Posterchild Media booking request',
        `Hi ${data.first_name || 'there'},\n\nThank you for contacting Posterchild Media! We received your booking request and will reach out within 24 hours to discuss your vision, confirm availability, and reserve your session.\n\n— Posterchild Media`,
        { name: BUSINESS_NAME }
      );
    }

    return ContentService
      .createTextOutput(JSON.stringify({ ok: true }))
      .setMimeType(ContentService.MimeType.JSON);
  } catch (err) {
    return ContentService
      .createTextOutput(JSON.stringify({ ok: false, error: String(err) }))
      .setMimeType(ContentService.MimeType.JSON);
  }
}
